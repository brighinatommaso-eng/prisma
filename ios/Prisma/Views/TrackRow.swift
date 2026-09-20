import Foundation
import SwiftData
import SwiftUI

// MARK: - Track row

/// Where a row sits inside a playlist, for Rimuovi dalla playlist. Both halves are
/// ids: the menu is opened and tapped long after the body that built it.
struct PlaylistPlacement: Equatable {
    let playlistID: UUID
    let entryID: UUID
}

/// The one row for a track, on every screen: Preferiti, playlists, Cerca and
/// Download. The prototype's `.trk`: leading slot, title and subtitle, duration, and
/// the trailing state slot, with any problem in plain language under it.
///
/// Takes a `TrackRowData`, never a `StoredTrack`: its screen read the store once and
/// handed down values (see `Projection`). The row may not have a library track at
/// all — a favourite added from Cerca has none — which is what `TrackRowData
/// .presence` says, and what decides here whether tapping plays, downloads, or
/// explains. Whatever it does, it reads the track back by id at the moment of the tap.
///
/// Tapping plays whatever can play: the file when the phone has one, and the server
/// when it does not and the server is answering. That decision is `TrackRowData
/// .canPlay`, the same rule `PlaybackEngine.canPlayNow` applies to the stored track,
/// so a row never offers a tap the engine will refuse.
///
/// `choosesDestination` is Preferiti: there a track that cannot play is not simply
/// downloaded, because the user picks where the copy goes, and a track that cannot
/// be played says why instead of doing nothing.
///
/// The long-press menu and the swipes come from `TrackMenu`, so every screen offers
/// the same actions. A screen chooses only what the row shows (leading and trailing
/// slots, subtitle) and, through `play`, which queue playback starts; without it the
/// queue is the track's album.
struct TrackRow<Leading: View, Trailing: View>: View {
    let data: TrackRowData
    let subtitle: String?
    let subtitleLineLimit: Int
    let showsDuration: Bool
    let placement: PlaylistPlacement?
    let choosesDestination: Bool
    let play: (() -> Void)?
    let leading: Leading
    let trailing: Trailing

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.modelContext) private var context
    @Environment(\.prismaInk) private var ink

    /// The destination sheet, by value: it stays up by itself while the library
    /// changes behind it.
    @State private var destination: AcquisitionRequest?

    init(
        data: TrackRowData,
        subtitle: String? = nil,
        subtitleLineLimit: Int = 1,
        showsDuration: Bool = true,
        placement: PlaylistPlacement? = nil,
        choosesDestination: Bool = false,
        play: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.data = data
        self.subtitle = subtitle
        self.subtitleLineLimit = subtitleLineLimit
        self.showsDuration = showsDuration
        self.placement = placement
        self.choosesDestination = choosesDestination
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
                            Text(data.title)
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
                            Text(Formatting.trackTime(data.durationS))
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

            TrackProblems(data: data)
        }
        .modifier(TrackMenu(
            data: data,
            placement: placement,
            play: { startPlayback() },
            chooseDestination: choosesDestination ? { destination = data.acquisitionRequest } : nil
        ))
        .sheet(item: $destination) { request in
            DestinationSheet(request: request, reason: data.favouriteState.reason(title: data.title, server: server))
        }
    }

    private var server: ServerState { ServerState(reachability.isReachable) }

    private func tap() {
        // The file first, the server second: a downloaded track plays from disk
        // even when the server is answering, and a track only the server has plays
        // by streaming while it answers.
        if data.canPlay(server) {
            startPlayback()
            return
        }
        if choosesDestination {
            // Preferiti: a row that will not play opens the choice, whose header is
            // the answer to the tap. A transfer already under way says so itself.
            guard !data.isBusy, downloads.preflights[data.id] == nil else { return }
            // The server may have come back since the last answer was recorded, and
            // the sheet is about to say it has not. Ask again while it is open.
            reachability.retry()
            destination = data.acquisitionRequest
            return
        }
        switch data.downloadState {
        case .notDownloaded, .cancelled, .failed:
            guard data.presence == .inLibrary,
                  downloads.preflights[data.id] == nil,
                  let track = ModelLookup.track(data.id, in: context) else { return }
            downloads.download(track)
        case .queued, .downloading, .downloaded:
            break
        }
    }

    private func startPlayback() {
        if let play {
            play()
        } else {
            guard let track = ModelLookup.track(data.id, in: context) else { return }
            presenter.sourceName = nil
            playback.play(track: track)
        }
    }
}

extension TrackRow where Trailing == TrackStateSlot {
    /// A row with the standard state icon on the right.
    init(
        data: TrackRowData,
        subtitle: String? = nil,
        placement: PlaylistPlacement? = nil,
        choosesDestination: Bool = false,
        play: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(
            data: data,
            subtitle: subtitle,
            placement: placement,
            choosesDestination: choosesDestination,
            play: play,
            leading: leading
        ) {
            TrackStateSlot(data: data)
        }
    }
}

/// The standard trailing slot: the download state icon, its 44 pt hit area reaching
/// the row's edge.
struct TrackStateSlot: View {
    let data: TrackRowData

    var body: some View {
        DownloadStateIcon(data: data)
            .padding(.trailing, -10)
    }
}

/// A track's current problems: a deletion running or failed, a refused download,
/// and a failed one.
struct TrackProblems: View {
    let data: TrackRowData

    @Environment(DownloadManager.self) private var downloads
    @Environment(TrackDeletion.self) private var deletion
    @Environment(\.prismaInk) private var ink

    var body: some View {
        if deletion.inProgress.contains(data.id) {
            Text("Eliminazione dal server in corso…")
                .font(.caption)
                .foregroundStyle(ink.secondary)
                .padding(.bottom, 8)
        }
        if let problem = deletion.problems[data.id] {
            VStack(alignment: .leading, spacing: 0) {
                ProblemBlock(error: problem)
                DismissLink { deletion.clearProblem(data.id) }
            }
        }
        if let refusal = downloads.refusals[data.id] {
            ProblemBlock(error: refusal)
        }
        if data.downloadState == .failed, downloads.preflights[data.id] == nil {
            ProblemBlock(PlainLanguage.message(for: data.failureCause))
        }
    }
}

// MARK: - Track menu

/// The long-press menu and swipes of every track row. Only what applies to the track
/// right now is listed; nothing is shown disabled.
///
/// - Riproduci, Aggiungi alla coda: the file is on the phone.
/// - Aggiungi a playlist…: there is a library track to point an entry at.
///   Preferito / Rimuovi dai preferiti: always, because a favourite needs no track.
///   Rimuovi dalla playlist: the row is inside a playlist.
/// - Scarica…: Preferiti, where the destination is chosen first. Scarica sul
///   telefono elsewhere: the server has it, it is not on the phone, nothing is
///   queued or downloading and no server check is running. Rimuovi dal telefono:
///   the file is on the phone.
/// - Elimina dal server: the server still has the track, and its deletion is not
///   already running. A track the server has already dropped, or one that was never
///   there, has nothing to delete.
///
/// What is listed comes from the values the row was given. What each item does is
/// read back from the store by id when it is tapped, because a menu is opened, and a
/// confirmation answered, long after the screen last looked.
///
/// Rimuovi dal telefono and Elimina dal server delete data, so they ask first.
struct TrackMenu: ViewModifier {
    let data: TrackRowData
    let placement: PlaylistPlacement?
    let play: () -> Void
    /// Preferiti opens the destination choice instead of starting a download here.
    let chooseDestination: (() -> Void)?

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlaylistStore.self) private var store
    @Environment(TrackDeletion.self) private var deletion
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.modelContext) private var context

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
                // By id: the sheet stays up on its own and the row behind it can be
                // deleted while it is open.
                AddToPlaylistSheet(trackID: data.id)
            }
            .destructiveConfirmation($confirmation)
    }

    @ViewBuilder
    private var menuItems: some View {
        // Two different questions, and the menu keeps them apart: what can be
        // played right now (a file here, or a stream while the server answers),
        // and what is actually on this phone (which is what Rimuovi dal telefono
        // acts on).
        let canPlay = data.canPlay(ServerState(reachability.isReachable))
        let onPhone = data.isOnPhone
        let canDownload = TrackAvailability.canDownload(data, downloads: downloads)
        let canChoose = chooseDestination != nil && !onPhone && !data.isBusy

        if canPlay {
            Section {
                Button(action: play) {
                    Label(data.isOnPhone ? "Riproduci" : "Riproduci in streaming",
                          systemImage: data.isOnPhone ? "play.fill" : "play.circle")
                }
                Button {
                    guard let track = ModelLookup.track(data.id, in: context) else { return }
                    playback.addToQueue(track)
                } label: {
                    Label("Aggiungi alla coda", systemImage: "text.append")
                }
            }
        }

        Section {
            if data.hasLibraryRow {
                Button {
                    addingToPlaylist = true
                } label: {
                    Label("Aggiungi a playlist…", systemImage: "text.badge.plus")
                }
            }
            if let placement {
                Button(role: .destructive) {
                    removeFromPlaylist(placement)
                } label: {
                    Label("Rimuovi dalla playlist", systemImage: "text.badge.minus")
                }
            }
            favouriteButton
        }

        if canChoose || canDownload || onPhone {
            Section {
                if let chooseDestination, canChoose {
                    Button(action: chooseDestination) {
                        Label("Scarica…", systemImage: "arrow.down.to.line")
                    }
                } else if canDownload {
                    Button {
                        download()
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

        if data.presence == .inLibrary, !deletion.inProgress.contains(data.id) {
            Section {
                Button(role: .destructive) {
                    confirmDeleteFromServer()
                } label: {
                    Label("Elimina dal server", systemImage: "trash")
                }
            }
        }
    }

    /// Favouriting needs no track: the collection is keyed by the video id, and the
    /// row carries everything a new favourite is made of.
    private var favouriteButton: some View {
        Button {
            store.toggleFavourite(data.favouriteDraft)
        } label: {
            Label(data.isFavourite ? "Rimuovi dai preferiti" : "Preferito",
                  systemImage: data.isFavourite ? "heart.slash" : "heart")
        }
    }

    /// Playlist removal inside a playlist, and the transfer controls that fit the
    /// download state: the same on every screen.
    @ViewBuilder
    private var trailingSwipes: some View {
        if let placement {
            Button("Rimuovi", role: .destructive) {
                removeFromPlaylist(placement)
            }
        }
        switch data.downloadState {
        case .queued, .downloading:
            Button("Annulla") {
                guard let track = ModelLookup.track(data.id, in: context) else { return }
                downloads.cancel(track)
            }
        case .failed, .cancelled:
            Button("Ignora") {
                guard let track = ModelLookup.track(data.id, in: context) else { return }
                downloads.dismiss(track)
            }
        case .notDownloaded, .downloaded:
            EmptyView()
        }
    }

    private func download() {
        guard let track = ModelLookup.track(data.id, in: context) else { return }
        downloads.download(track)
    }

    private func removeFromPlaylist(_ placement: PlaylistPlacement) {
        guard let playlist = ModelLookup.playlist(placement.playlistID, in: context),
              let entry = ModelLookup.playlistEntry(placement.entryID, in: context) else { return }
        store.remove([entry], from: playlist)
    }

    // The two confirmations below sit in `@State` until the user answers the dialog,
    // which is long enough for a sync to delete the track. They carry its id and the
    // title it had when the question was asked, and read the track back at the tap.

    private func confirmRemoveFromPhone() {
        let id = data.id
        let downloads = self.downloads
        let context = self.context
        // A phone-only track has no copy anywhere else: the file here is the whole
        // track, and the row says so rather than promising it can be downloaded again
        // as it is. It can be fetched again, but from YouTube, through the server.
        let message = data.presence == .phoneOnly
            ? "Questa è l’unica copia: il server non ha più questo brano, perché lo avevi scaricato solo sul telefono. Eliminando il file resta il preferito, e per riascoltarlo il brano va fatto riscaricare dal server."
            : "Il file audio viene eliminato da questo iPhone. Il brano resta in libreria, nelle playlist e nei preferiti: per riascoltarlo va scaricato di nuovo."
        confirmation = DestructiveConfirmation(
            title: "Rimuovere “\(data.title)” dal telefono?",
            message: message,
            button: "Rimuovi dal telefono"
        ) {
            guard let track = ModelLookup.track(id, in: context), track.downloadState == .downloaded else { return }
            downloads.removeFile(track)
        }
    }

    private func confirmDeleteFromServer() {
        let id = data.id
        let deletion = self.deletion
        let context = self.context
        confirmation = DestructiveConfirmation(
            title: "Eliminare “\(data.title)” dal server?",
            message: "Il brano e il suo file vengono eliminati dal server, poi spariscono da libreria, playlist, preferiti e da questo iPhone. Per riaverlo va cercato e scaricato di nuovo da Cerca.",
            button: "Elimina dal server"
        ) {
            guard let track = ModelLookup.track(id, in: context) else { return }
            deletion.delete([track], reportingUnder: id)
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
/// Takes the collection's members as values, like every row does, and acts on their
/// ids. The two removals ask first, naming how many tracks they touch.
struct CollectionMenu: ViewModifier {
    let tracks: [TrackRowData]
    let name: String
    /// Where this collection's deletion problems are kept, e.g. "album-3".
    let problemKey: String

    @Environment(DownloadManager.self) private var downloads
    @Environment(TrackDeletion.self) private var deletion
    @Environment(\.modelContext) private var context
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

    /// Each track once, in the collection's order.
    private var members: [TrackRowData] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }

    @ViewBuilder
    private var menuItems: some View {
        let members = self.members
        let missing = members.filter { TrackAvailability.canDownload($0, downloads: downloads) }
        let onPhone = members.filter { $0.downloadState == .downloaded }
        // Only what the server still has: a playlist can now hold a track that is in
        // no library at all, and DELETE /tracks/{id} has nothing to delete for it.
        // The single-track menu already asks the same question.
        let deletable = members.filter { $0.presence == .inLibrary && !deletion.inProgress.contains($0.id) }

        if !missing.isEmpty || !onPhone.isEmpty {
            Section {
                if !missing.isEmpty {
                    Button {
                        for track in ModelLookup.tracks(missing.map(\.id), in: context) {
                            downloads.download(track)
                        }
                    } label: {
                        Label("Scarica tutto", systemImage: "arrow.down.to.line")
                    }
                }
                if !onPhone.isEmpty {
                    Button(role: .destructive) {
                        confirmRemoveFromPhone(onPhone.map(\.id))
                    } label: {
                        Label("Rimuovi tutto dal telefono", systemImage: "iphone.slash")
                    }
                }
            }
        }

        if !deletable.isEmpty {
            Section {
                Button(role: .destructive) {
                    confirmDeleteFromServer(deletable.map(\.id))
                } label: {
                    Label("Elimina tutto dal server", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var problems: some View {
        // Ids alone: counting what is being deleted touches no row at all.
        let deleting = members.filter { deletion.inProgress.contains($0.id) }.count
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

    // Both confirmations are answered later, so they carry ids and read the tracks
    // back when the button is tapped. The count in the title is the count at the
    // moment of asking, which is what the user is agreeing to.

    private func confirmRemoveFromPhone(_ ids: [String]) {
        let downloads = self.downloads
        let context = self.context
        // Counted from the values, so the warning names how many of these files are
        // the only copy there is.
        let onlyCopies = members.filter { ids.contains($0.id) && $0.presence == .phoneOnly }.count
        let warning = onlyCopies == 0 ? ""
            : onlyCopies == 1
                ? " Di 1 brano questa è l’unica copia: il server non ce l’ha più, e per riaverlo va fatto riscaricare dal server."
                : " Di \(onlyCopies) brani questa è l’unica copia: il server non ce li ha più, e per riaverli vanno fatti riscaricare dal server."
        confirmation = DestructiveConfirmation(
            title: ids.count == 1 ? "Rimuovere 1 brano dal telefono?" : "Rimuovere \(ids.count) brani dal telefono?",
            message: "I file audio di “\(name)” vengono eliminati da questo iPhone. I brani restano in libreria, nelle playlist e nei preferiti: per riascoltarli vanno scaricati di nuovo." + warning,
            button: "Rimuovi dal telefono"
        ) {
            for track in ModelLookup.tracks(ids, in: context) where track.downloadState == .downloaded {
                downloads.removeFile(track)
            }
        }
    }

    private func confirmDeleteFromServer(_ ids: [String]) {
        let deletion = self.deletion
        let problemKey = self.problemKey
        let context = self.context
        confirmation = DestructiveConfirmation(
            title: ids.count == 1 ? "Eliminare 1 brano dal server?" : "Eliminare \(ids.count) brani dal server?",
            message: "I brani di “\(name)” e i loro file vengono eliminati dal server, poi spariscono da libreria, da ogni playlist, dai preferiti e da questo iPhone. Per riaverli vanno cercati e scaricati di nuovo da Cerca.",
            button: "Elimina dal server"
        ) {
            deletion.delete(ModelLookup.tracks(ids, in: context), reportingUnder: problemKey)
        }
    }
}

// MARK: - Shared pieces

enum TrackAvailability {
    /// On the server but not on the phone, with nothing already under way.
    ///
    /// The device download fetches GET /tracks/{id}/file, so it needs a track the
    /// server still has: a favourite with no library row, and a track whose only
    /// copy is here because the server dropped it, both have to go through the
    /// server first and are not offered a download that would only 404.
    static func canDownload(_ data: TrackRowData, downloads: DownloadManager) -> Bool {
        guard data.presence == .inLibrary else { return false }
        switch data.downloadState {
        case .notDownloaded, .failed, .cancelled:
            return downloads.preflights[data.id] == nil
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
