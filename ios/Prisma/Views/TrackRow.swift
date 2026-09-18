import Foundation
import SwiftData
import SwiftUI

// MARK: - Track row

/// Where a row sits inside a playlist, for Rimuovi dalla playlist.
struct PlaylistPlacement {
    let playlist: Playlist
    let entry: PlaylistEntry
}

/// The one row for a library track, on every screen: Libreria, Preferiti, playlists,
/// Cerca and Download. The prototype's `.trk`: leading slot, title and subtitle,
/// duration, and the trailing state slot, with any problem in plain language under it.
///
/// Tapping plays the track when its file is on the phone, and starts its download
/// when it is not. The long-press menu and the swipes come from `TrackMenu`, so every
/// screen offers the same actions. A screen chooses only what the row shows (leading
/// and trailing slots, subtitle) and, through `play`, which queue playback starts;
/// without it the queue is the track's album.
struct TrackRow<Leading: View, Trailing: View>: View {
    let track: StoredTrack
    let subtitle: String?
    let subtitleLineLimit: Int
    let showsDuration: Bool
    /// Problems from outside the track, e.g. artwork that failed to load.
    let extraProblem: APIError?
    let placement: PlaylistPlacement?
    let play: (() -> Void)?
    let leading: Leading
    let trailing: Trailing

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(\.prismaInk) private var ink

    init(
        track: StoredTrack,
        subtitle: String? = nil,
        subtitleLineLimit: Int = 1,
        showsDuration: Bool = true,
        extraProblem: APIError? = nil,
        placement: PlaylistPlacement? = nil,
        play: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.track = track
        self.subtitle = subtitle
        self.subtitleLineLimit = subtitleLineLimit
        self.showsDuration = showsDuration
        self.extraProblem = extraProblem
        self.placement = placement
        self.play = play
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: tap) {
                    HStack(spacing: 13) {
                        leading
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title ?? "Senza titolo")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(ink.primary)
                                .lineLimit(1)
                            if let subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(ink.secondary)
                                    .lineLimit(subtitleLineLimit)
                            }
                        }
                        Spacer(minLength: 0)
                        if showsDuration {
                            Text(Formatting.trackTime(track.durationS))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ink.secondary)
                        }
                    }
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                trailing
            }

            TrackProblems(track: track, extraProblem: extraProblem)
        }
        .modifier(TrackMenu(track: track, placement: placement, play: { startPlayback() }))
    }

    private func tap() {
        switch track.downloadState {
        case .downloaded:
            startPlayback()
        case .notDownloaded, .cancelled, .failed:
            if downloads.preflights[track.serverID] == nil {
                downloads.download(track)
            }
        case .queued, .downloading:
            break
        }
    }

    private func startPlayback() {
        if let play {
            play()
        } else {
            presenter.sourceName = nil
            playback.play(track: track)
        }
    }
}

extension TrackRow where Trailing == TrackStateSlot {
    /// A row with the standard state icon on the right.
    init(
        track: StoredTrack,
        subtitle: String? = nil,
        extraProblem: APIError? = nil,
        placement: PlaylistPlacement? = nil,
        play: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(track: track, subtitle: subtitle, extraProblem: extraProblem, placement: placement, play: play, leading: leading) {
            TrackStateSlot(track: track)
        }
    }
}

/// The standard trailing slot: the download state icon, its 44 pt hit area reaching
/// the row's edge.
struct TrackStateSlot: View {
    let track: StoredTrack

    var body: some View {
        DownloadStateIcon(track: track)
            .padding(.trailing, -10)
    }
}

/// A track's current problems: a deletion running or failed, a refused download, a
/// failed one, and anything the row itself adds.
struct TrackProblems: View {
    let track: StoredTrack
    var extraProblem: APIError?

    @Environment(DownloadManager.self) private var downloads
    @Environment(TrackDeletion.self) private var deletion
    @Environment(\.prismaInk) private var ink

    var body: some View {
        if deletion.inProgress.contains(track.serverID) {
            Text("Eliminazione dal server in corso…")
                .font(.caption)
                .foregroundStyle(ink.secondary)
                .padding(.bottom, 8)
        }
        if let problem = deletion.problems[track.serverID] {
            VStack(alignment: .leading, spacing: 0) {
                ProblemBlock(error: problem)
                DismissLink { deletion.clearProblem(track.serverID) }
            }
        }
        if let refusal = downloads.refusals[track.serverID] {
            ProblemBlock(error: refusal)
        }
        if track.downloadState == .failed, downloads.preflights[track.serverID] == nil {
            ProblemBlock(PlainLanguage.message(for: track.failureCause))
        }
        if let extraProblem {
            ProblemBlock(error: extraProblem)
        }
    }
}

// MARK: - Track menu

/// The long-press menu and swipes of every track row. Only what applies to the track
/// right now is listed; nothing is shown disabled.
///
/// - Riproduci, Aggiungi alla coda: the file is on the phone.
/// - Aggiungi a playlist…, Preferito / Rimuovi dai preferiti: always (the row is a
///   library track). Rimuovi dalla playlist: the row is inside a playlist.
/// - Scarica sul telefono: not on the phone, not queued or downloading, and no
///   server check running. Rimuovi dal telefono: the file is on the phone.
/// - Elimina dal server: always, unless its deletion is already running.
///
/// Rimuovi dal telefono and Elimina dal server delete data, so they ask first.
struct TrackMenu: ViewModifier {
    let track: StoredTrack
    let placement: PlaylistPlacement?
    let play: () -> Void

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlaylistStore.self) private var store
    @Environment(TrackDeletion.self) private var deletion

    @State private var addingToPlaylist = false
    @State private var confirmation: DestructiveConfirmation?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                menuItems
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                favouriteButton
                    .tint(.pink)
            }
            .swipeActions(edge: .trailing) {
                trailingSwipes
            }
            .sheet(isPresented: $addingToPlaylist) {
                AddToPlaylistSheet(track: track)
            }
            .destructiveConfirmation($confirmation)
    }

    @ViewBuilder
    private var menuItems: some View {
        let onPhone = track.downloadState == .downloaded
        let canDownload = TrackAvailability.canDownload(track, downloads: downloads)

        if onPhone {
            Section {
                Button(action: play) {
                    Label("Riproduci", systemImage: "play.fill")
                }
                Button {
                    playback.addToQueue(track)
                } label: {
                    Label("Aggiungi alla coda", systemImage: "text.append")
                }
            }
        }

        Section {
            Button {
                addingToPlaylist = true
            } label: {
                Label("Aggiungi a playlist…", systemImage: "text.badge.plus")
            }
            if let placement {
                Button(role: .destructive) {
                    store.remove([placement.entry], from: placement.playlist)
                } label: {
                    Label("Rimuovi dalla playlist", systemImage: "text.badge.minus")
                }
            }
            favouriteButton
        }

        if canDownload || onPhone {
            Section {
                if canDownload {
                    Button {
                        downloads.download(track)
                    } label: {
                        Label("Scarica sul telefono", systemImage: "arrow.down.to.line")
                    }
                }
                if onPhone {
                    Button(role: .destructive) {
                        confirmRemoveFromPhone()
                    } label: {
                        Label("Rimuovi dal telefono", systemImage: "iphone.slash")
                    }
                }
            }
        }

        if !deletion.inProgress.contains(track.serverID) {
            Section {
                Button(role: .destructive) {
                    confirmDeleteFromServer()
                } label: {
                    Label("Elimina dal server", systemImage: "trash")
                }
            }
        }
    }

    private var favouriteButton: some View {
        Button {
            store.toggleFavourite(track)
        } label: {
            Label(track.isFavourite ? "Rimuovi dai preferiti" : "Preferito",
                  systemImage: track.isFavourite ? "heart.slash" : "heart")
        }
    }

    /// Playlist removal inside a playlist, and the transfer controls that fit the
    /// download state: the same on every screen.
    @ViewBuilder
    private var trailingSwipes: some View {
        if let placement {
            Button("Rimuovi", role: .destructive) {
                store.remove([placement.entry], from: placement.playlist)
            }
        }
        switch track.downloadState {
        case .queued, .downloading:
            Button("Annulla") {
                downloads.cancel(track)
            }
        case .failed, .cancelled:
            Button("Ignora") {
                downloads.dismiss(track)
            }
        case .notDownloaded, .downloaded:
            EmptyView()
        }
    }

    private func confirmRemoveFromPhone() {
        let track = self.track
        let downloads = self.downloads
        confirmation = DestructiveConfirmation(
            title: "Rimuovere “\(track.title ?? "Senza titolo")” dal telefono?",
            message: "Il file audio viene eliminato da questo iPhone. Il brano resta in libreria, nelle playlist e nei preferiti: per riascoltarlo va scaricato di nuovo.",
            button: "Rimuovi dal telefono"
        ) {
            guard !track.isDeleted, track.downloadState == .downloaded else { return }
            downloads.removeFile(track)
        }
    }

    private func confirmDeleteFromServer() {
        let track = self.track
        let deletion = self.deletion
        confirmation = DestructiveConfirmation(
            title: "Eliminare “\(track.title ?? "Senza titolo")” dal server?",
            message: "Il brano e il suo file vengono eliminati dal server, poi spariscono da libreria, playlist, preferiti e da questo iPhone. Per riaverlo va cercato e scaricato di nuovo da Cerca.",
            button: "Elimina dal server"
        ) {
            guard !track.isDeleted else { return }
            deletion.delete([track], reportingUnder: track.serverID)
        }
    }
}

// MARK: - Collection menu

/// The long-press menu of an album or playlist header, acting on all its tracks,
/// with the collection's deletion progress and problems under the header. Only
/// what applies is listed:
///
/// - Scarica tutto: at least one track could start downloading (see `TrackMenu`).
/// - Rimuovi tutto dal telefono: at least one track is on the phone.
/// - Elimina tutto dal server: at least one track is not already being deleted.
///
/// The two removals ask first, naming how many tracks they touch.
struct CollectionMenu: ViewModifier {
    /// The collection's current members, read again at every body rather than kept
    /// as an array. A stored array would be a snapshot of live `StoredTrack`
    /// objects: this modifier renders again whenever `TrackDeletion` changes, and
    /// its owner (the album or playlist header) does not, so a snapshot taken before
    /// a deletion would still be here afterwards and reading it would trap.
    let members: () -> [StoredTrack]
    let name: String
    /// Where this collection's deletion problems are kept, e.g. "album-3".
    let problemKey: String

    @Environment(DownloadManager.self) private var downloads
    @Environment(TrackDeletion.self) private var deletion
    @Environment(\.prismaInk) private var ink

    @State private var confirmation: DestructiveConfirmation?

    func body(content: Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .contextMenu {
                    menuItems
                }
            problems
        }
        .destructiveConfirmation($confirmation)
    }

    /// Each track once, without any awaiting deletion in the open context.
    private var distinctMembers: [StoredTrack] {
        var seen = Set<String>()
        return members().filter { !$0.isDeleted && seen.insert($0.serverID).inserted }
    }

    @ViewBuilder
    private var menuItems: some View {
        let tracks = distinctMembers
        let missing = tracks.filter { TrackAvailability.canDownload($0, downloads: downloads) }
        let onPhone = tracks.filter { $0.downloadState == .downloaded }
        let deletable = tracks.filter { !deletion.inProgress.contains($0.serverID) }

        if !missing.isEmpty || !onPhone.isEmpty {
            Section {
                if !missing.isEmpty {
                    Button {
                        for track in missing {
                            downloads.download(track)
                        }
                    } label: {
                        Label("Scarica tutto", systemImage: "arrow.down.to.line")
                    }
                }
                if !onPhone.isEmpty {
                    Button(role: .destructive) {
                        confirmRemoveFromPhone(onPhone)
                    } label: {
                        Label("Rimuovi tutto dal telefono", systemImage: "iphone.slash")
                    }
                }
            }
        }

        if !deletable.isEmpty {
            Section {
                Button(role: .destructive) {
                    confirmDeleteFromServer(deletable)
                } label: {
                    Label("Elimina tutto dal server", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var problems: some View {
        let deleting = distinctMembers.filter { deletion.inProgress.contains($0.serverID) }.count
        if deleting > 0 {
            Text(deleting == 1 ? "Eliminazione di 1 brano dal server in corso…" : "Eliminazione di \(deleting) brani dal server in corso…")
                .font(.caption)
                .foregroundStyle(ink.secondary)
                .padding(.top, 8)
        }
        if let problem = deletion.problems[problemKey] {
            VStack(alignment: .leading, spacing: 0) {
                ProblemBlock(error: problem)
                DismissLink { deletion.clearProblem(problemKey) }
            }
        }
    }

    private func confirmRemoveFromPhone(_ targets: [StoredTrack]) {
        let downloads = self.downloads
        confirmation = DestructiveConfirmation(
            title: targets.count == 1 ? "Rimuovere 1 brano dal telefono?" : "Rimuovere \(targets.count) brani dal telefono?",
            message: "I file audio di “\(name)” vengono eliminati da questo iPhone. I brani restano in libreria, nelle playlist e nei preferiti: per riascoltarli vanno scaricati di nuovo.",
            button: "Rimuovi dal telefono"
        ) {
            for track in targets where !track.isDeleted && track.downloadState == .downloaded {
                downloads.removeFile(track)
            }
        }
    }

    private func confirmDeleteFromServer(_ targets: [StoredTrack]) {
        let deletion = self.deletion
        let problemKey = self.problemKey
        confirmation = DestructiveConfirmation(
            title: targets.count == 1 ? "Eliminare 1 brano dal server?" : "Eliminare \(targets.count) brani dal server?",
            message: "I brani di “\(name)” e i loro file vengono eliminati dal server, poi spariscono da libreria, da ogni playlist, dai preferiti e da questo iPhone. Per riaverli vanno cercati e scaricati di nuovo da Cerca.",
            button: "Elimina dal server"
        ) {
            deletion.delete(targets, reportingUnder: problemKey)
        }
    }
}

// MARK: - Shared pieces

enum TrackAvailability {
    /// On the server but not on the phone, with nothing already under way.
    static func canDownload(_ track: StoredTrack, downloads: DownloadManager) -> Bool {
        switch track.downloadState {
        case .notDownloaded, .failed, .cancelled:
            return downloads.preflights[track.serverID] == nil
        case .queued, .downloading, .downloaded:
            return false
        }
    }
}

/// A destructive action waiting for its confirmation dialog.
struct DestructiveConfirmation {
    let title: String
    let message: String
    let button: String
    let action: () -> Void
}

extension View {
    /// Asks before a destructive action: its title and message, the action in red,
    /// and Annulla.
    func destructiveConfirmation(_ confirmation: Binding<DestructiveConfirmation?>) -> some View {
        confirmationDialog(
            confirmation.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { confirmation.wrappedValue != nil },
                set: { if !$0 { confirmation.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmation.wrappedValue
        ) { pending in
            Button(pending.button, role: .destructive) {
                pending.action()
            }
            Button("Annulla", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }
}
