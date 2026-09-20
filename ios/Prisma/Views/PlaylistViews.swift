import Foundation
import SwiftData
import SwiftUI

/// The two halves of the Library tab.
///
/// There is no album segment: albums are still what a cover and an artist name come
/// from, but they are not browsed. Preferiti is the collection, and a track reaches
/// it from Cerca or from the library it was already in.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case favourites
    case playlists

    var id: String { rawValue }

    var label: String {
        switch self {
        case .favourites: return "Preferiti"
        case .playlists: return "Playlist"
        }
    }
}

/// A heart that adds the track to Preferiti or takes it out, with the whole
/// `hitSize` area tappable (a plain button otherwise responds only on the drawn
/// glyph).
///
/// Takes a draft rather than an id: a favourite is keyed by the video id and needs
/// no track, so this works on a search result that is in no library at all.
struct FavouriteButton: View {
    let draft: FavouriteDraft
    let isFavourite: Bool
    var hitSize = CGSize(width: 44, height: 44)
    var glyphSize: CGFloat = 19

    @Environment(PlaylistStore.self) private var store
    @Environment(\.prismaInk) private var ink

    var body: some View {
        Button {
            store.toggleFavourite(draft)
        } label: {
            Image(systemName: isFavourite ? "heart.fill" : "heart")
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(isFavourite ? ink.favourite : ink.secondary)
                .frame(width: hitSize.width, height: hitSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavourite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
    }
}

/// Errors and notices from playlist actions, with a way to dismiss them.
struct PlaylistStoreMessages: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.prismaInk) private var ink

    var body: some View {
        if let error = store.lastError {
            VStack(alignment: .leading, spacing: 0) {
                ProblemBlock(error: error)
                DismissLink { store.clearError() }
            }
            .prismaRow()
        }
        if let notice = store.notice {
            VStack(alignment: .leading, spacing: 0) {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(ink.secondary)
                    .padding(.top, 8)
                DismissLink { store.clearNotice() }
            }
            .prismaRow()
        }
    }
}

/// A small "Chiudi" link, 44 pt tall.
struct DismissLink: View {
    let action: () -> Void

    @Environment(\.prismaInk) private var ink

    var body: some View {
        Button(action: action) {
            Text("Chiudi")
                .font(.caption.weight(.semibold))
                .foregroundStyle(ink.accentText)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Playlists filter

struct PlaylistsContent: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.prismaInk) private var ink
    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]
    @Query private var entries: [PlaylistEntry]

    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: PlaylistSummaryData?
    @State private var renameText = ""

    var body: some View {
        // The one place this filter reads the store.
        let summaries = Projection.playlistSummaries(playlists, entries: entries)

        Button {
            newName = ""
            creating = true
        } label: {
            Label("Nuova playlist", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink.accentText)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .prismaRow()
        .listRowSeparator(.hidden, edges: .top)
        .alert("Nuova playlist", isPresented: $creating) {
            TextField("Nome", text: $newName)
            Button("Crea") { store.createPlaylist(named: newName) }
            Button("Annulla", role: .cancel) {}
        }
        .alert("Rinomina playlist", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Nome", text: $renameText)
            Button("Rinomina") {
                if let renaming, let playlist = ModelLookup.playlist(renaming.id, in: context) {
                    store.rename(playlist, to: renameText)
                }
            }
            Button("Annulla", role: .cancel) {}
        }

        PlaylistStoreMessages()

        if summaries.isEmpty {
            Text("Nessuna playlist. Tocca Nuova playlist per crearne una.")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
                .padding(.vertical, 12)
                .prismaRow()
        }

        ForEach(summaries) { summary in
            NavigationLink {
                PlaylistDetailView(playlistID: summary.id, name: summary.name)
            } label: {
                PlaylistSummaryRow(summary: summary)
            }
            .swipeActions(edge: .trailing) {
                Button("Elimina", role: .destructive) {
                    store.delete(ModelLookup.playlists([summary.id], in: context))
                }
                Button("Rinomina") {
                    renameText = summary.name
                    renaming = summary
                }
            }
            .prismaRow()
        }
        // No onDelete: its edit-mode button would read "Delete". Swipe offers Elimina.
        .onMove { source, destination in
            // The offsets belong to the list as projected, so the resolved playlists
            // must still be that same list; if one has gone the list is about to be
            // drawn again and the drop is simply not applied.
            let resolved = ModelLookup.playlists(summaries.map(\.id), in: context)
            guard resolved.count == summaries.count else { return }
            store.movePlaylists(resolved, from: source, to: destination)
        }
    }
}

private struct PlaylistSummaryRow: View {
    let summary: PlaylistSummaryData

    @Environment(\.prismaInk) private var ink

    var body: some View {
        HStack(spacing: 13) {
            PlaylistMosaic(covers: summary.covers, side: 62, cornerRadius: 14)
                .shadow(color: .black.opacity(0.45), radius: 11, y: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.name)
                    .font(.headline)
                    .foregroundStyle(ink.primary)
                    .lineLimit(2)
                Text(Formatting.trackSummary(summary.tracks))
                    .font(.caption)
                    .foregroundStyle(ink.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    let playlistID: UUID
    /// The name the list screen knew when it pushed this, so the title is right even
    /// in the moment before the first projection.
    let name: String

    @Environment(PlaylistStore.self) private var store
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.modelContext) private var context
    @Environment(\.prismaInk) private var ink
    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]
    @Query private var allEntries: [PlaylistEntry]

    @State private var renaming = false
    @State private var renameText = ""
    @State private var editMode: EditMode = .inactive

    var body: some View {
        // The one place this screen reads the store.
        let data = Projection.playlist(id: playlistID, playlists: playlists, entries: allEntries)

        List {
            if let data {
                content(data)
            }
        }
        .prismaList()
        .environment(\.editMode, $editMode)
        .navigationTitle(data?.name ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditModeButton(editMode: $editMode)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = data?.name ?? name
                        renaming = true
                    } label: {
                        Label("Rinomina…", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Altre azioni")
            }
        }
        .alert("Rinomina playlist", isPresented: $renaming) {
            TextField("Nome", text: $renameText)
            Button("Rinomina") {
                guard let playlist = ModelLookup.playlist(playlistID, in: context) else { return }
                store.rename(playlist, to: renameText)
            }
            Button("Annulla", role: .cancel) {}
        }
        // Pushed inside a tab, so it needs the mini player inset itself.
        .miniPlayerInset()
        .themedScreenBackground()
    }

    @ViewBuilder
    private func content(_ data: PlaylistData) -> some View {
        header(data)
            .prismaRow()
            .listRowSeparator(.hidden, edges: .top)

        PlaylistStoreMessages()

        if data.rows.isEmpty {
            Text("Questa playlist è vuota. Aggiungi brani da Libreria o Cerca tenendo premuto su un brano.")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
                .padding(.vertical, 12)
                .prismaRow()
        }

        ForEach(Array(data.rows.enumerated()), id: \.element.id) { index, row in
            Group {
                if let track = row.track {
                    TrackRow(
                        data: track,
                        subtitle: track.artist,
                        placement: PlaylistPlacement(playlistID: data.id, entryID: row.entryID),
                        play: {
                            presenter.sourceName = data.name
                            play(fromEntryAt: index)
                        }
                    ) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ink.secondary)
                            .frame(width: 18, alignment: .leading)
                    }
                } else {
                    MissingEntryRow(playlistID: data.id, entryID: row.entryID)
                }
            }
            .prismaRow()
        }
        .onMove { source, destination in
            move(rows: data.rows, from: source, to: destination)
        }

        if data.missingCount > 0 {
            Button {
                guard let playlist = ModelLookup.playlist(playlistID, in: context) else { return }
                store.downloadMissing(in: playlist)
            } label: {
                Text(data.missingCount == 1 ? "Scarica 1 brano mancante" : "Scarica \(data.missingCount) brani mancanti")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ink.accentText)
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .prismaRow()
        }
    }

    /// Mosaic, name, "N brani · N min", then Riproduci and Casuale side by side.
    /// Long press on the mosaic and name offers the playlist-wide actions of
    /// `CollectionMenu`; the buttons keep their own press.
    private func header(_ data: PlaylistData) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                PlaylistMosaic(covers: data.covers, side: 160, cornerRadius: 20)
                    .shadow(color: .black.opacity(0.6), radius: 23, y: 18)
                    .padding(.top, 20)
                Text(data.name)
                    .font(.title.weight(.heavy))
                    .foregroundStyle(ink.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 18)
                Text(Formatting.trackSummary(data.tracks))
                    .font(.footnote)
                    .foregroundStyle(ink.secondary)
                    .padding(.top, 5)
            }
            .frame(maxWidth: .infinity)
            .modifier(CollectionMenu(
                tracks: data.tracks,
                name: data.name,
                problemKey: "playlist-\(data.id.uuidString)"
            ))

            // What can play now, which with the server answering includes the
            // entries that are only on it.
            let playable = data.playable(ServerState(reachability.isReachable))
            PlayShufflePair(isEnabled: !playable.isEmpty) {
                guard let first = playable.first else { return }
                // Riproduci plays in playlist order, even if shuffle was left on.
                playback.setShuffle(false)
                presenter.sourceName = data.name
                play(fromEntryAt: first)
            } onShuffle: {
                // Starts shuffled: shuffle on first, so the new queue is built
                // shuffled from a random playable entry.
                guard let start = playable.randomElement() else { return }
                playback.setShuffle(true)
                presenter.sourceName = data.name
                play(fromEntryAt: start)
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 22)
    }

    private func play(fromEntryAt index: Int) {
        guard let playlist = ModelLookup.playlist(playlistID, in: context) else { return }
        store.play(playlist, fromEntryAt: index)
    }

    private func move(rows: [PlaylistRowData], from source: IndexSet, to destination: Int) {
        // The offsets belong to the list as projected, so the resolved entries must
        // still be that same list; if one has gone the list is about to be drawn
        // again and the drop is simply not applied.
        guard let playlist = ModelLookup.playlist(playlistID, in: context) else { return }
        let resolved = ModelLookup.playlistEntries(rows.map(\.entryID), in: context)
        guard resolved.count == rows.count else { return }
        store.moveEntries(in: playlist, ordered: resolved, from: source, to: destination)
    }
}

/// An entry whose track has left the library. Not a track row: there is no track
/// left to act on, only the entry to remove.
private struct MissingEntryRow: View {
    let playlistID: UUID
    let entryID: UUID

    @Environment(PlaylistStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.prismaInk) private var ink

    var body: some View {
        HStack {
            Text("Brano non più in libreria")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
            Spacer(minLength: 0)
            Button {
                remove()
            } label: {
                Text("Rimuovi")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ink.accentText)
                    .frame(minWidth: 44, minHeight: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing) {
            Button("Rimuovi", role: .destructive) {
                remove()
            }
        }
    }

    private func remove() {
        guard let playlist = ModelLookup.playlist(playlistID, in: context),
              let entry = ModelLookup.playlistEntry(entryID, in: context) else { return }
        store.remove([entry], from: playlist)
    }
}

// MARK: - Add to playlist

/// Adds a track to a playlist. A track may be added to the same playlist again.
struct AddToPlaylistSheet: View {
    /// The track by id: this sheet stays open by itself, so the row it was opened
    /// from can be deleted underneath it.
    let trackID: String

    @Environment(PlaylistStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]
    @Query private var tracks: [StoredTrack]
    @Query private var entries: [PlaylistEntry]

    @State private var newName = ""

    var body: some View {
        // The one place this sheet reads the store.
        let data = Projection.addToPlaylist(trackID: trackID, tracks: tracks, playlists: playlists, entries: entries)

        NavigationStack {
            List {
                if let track = data.track {
                    content(track, albumLine: data.albumLine, targets: data.targets)
                } else {
                    Section {
                        Text("Questo brano non è più in libreria, quindi non si può aggiungere a una playlist.")
                    }
                }
            }
            .navigationTitle("Aggiungi a playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ track: TrackRowData, albumLine: String?, targets: [PlaylistTargetData]) -> some View {
        Section {
            Text(track.title)
            if let albumLine {
                Text(albumLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            TextField("Nome della playlist", text: $newName)
            Button("Crea e aggiungi") {
                guard let stored = ModelLookup.track(trackID, in: context),
                      let playlist = store.createPlaylist(named: newName) else { return }
                store.add(stored, to: playlist)
                dismiss()
            }
        } header: {
            Text("Nuova playlist").textCase(nil)
        }

        Section {
            if targets.isEmpty {
                Text("Nessuna playlist.")
            }
            ForEach(targets) { target in
                Button {
                    add(to: target.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                        Text(Formatting.trackCount(target.entryCount)
                             + (target.holdsTrack ? " · contiene già questo brano, verrà aggiunto di nuovo" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Aggiungi a").textCase(nil)
        }

        if let error = store.lastError {
            Section {
                ProblemBlock(error: error)
                Button("Chiudi") { store.clearError() }
            }
        }
    }

    private func add(to playlistID: UUID) {
        guard let stored = ModelLookup.track(trackID, in: context),
              let playlist = ModelLookup.playlist(playlistID, in: context) else { return }
        store.add(stored, to: playlist)
        dismiss()
    }
}

// MARK: - Preferiti

/// Preferiti: the collection. A flat list of tracks, newest favourite first, with no
/// album grouping — each row's icon is the cover of the album its track belongs to.
///
/// A favourite is in one of three states and the row says which: on the phone,
/// where it plays with or without a network; on the server, where it plays by
/// streaming while the server answers and not at all when it does not; and not
/// acquired, where it is on neither. The last two are still real rows with a real
/// title, because a favourite added from Cerca with the plus downloads nothing.
struct FavouritesContent: View {
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.prismaInk) private var ink
    @Query private var favourites: [FavouriteTrack]
    @Query private var tracks: [StoredTrack]
    @Query private var acquisitions: [PendingAcquisition]

    var body: some View {
        // The one place this filter reads the store.
        let rows = Projection.favourites(favourites: favourites, tracks: tracks, acquisitions: acquisitions)
        let server = ServerState(reachability.isReachable)

        if !rows.isEmpty {
            PlayShuffleButtons(tracks: rows, sourceName: "Preferiti")
                .padding(.top, 12)
                .padding(.bottom, 6)
                .prismaRow()
                .listRowSeparator(.hidden)
        }

        PlaylistStoreMessages()

        // Said only when it changes what the user can do: some favourites are only
        // on the server, and the server is not answering, so those rows will not
        // play until it does.
        if server == .unreachable, rows.contains(where: { $0.isOnServerOnly }) {
            ProblemBlock(reachability.statusLine)
                .prismaRow()
                .listRowSeparator(.hidden)
        }

        if rows.isEmpty {
            Text("Nessun preferito. Cerca un brano e tocca + per aggiungerlo qui, oppure la freccia per scaricarlo subito.")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
                .padding(.vertical, 16)
                .prismaRow()
                .listRowSeparator(.hidden)
        }

        ForEach(rows) { row in
            FavouriteRow(data: row, server: server)
                .prismaRow()
        }

        if !rows.isEmpty {
            Text(Self.summary(of: rows, server: server))
                .font(.caption)
                .foregroundStyle(ink.secondary)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .prismaRow()
                .listRowSeparator(.hidden)
        }
    }

    /// How the collection is spread over the three states, counted from the values
    /// the projection produced, and what the server's state makes of it.
    static func summary(of rows: [TrackRowData], server: ServerState) -> String {
        let onPhone = rows.filter { $0.favouriteState == .onPhone }.count
        let onServer = rows.filter { $0.favouriteState == .onServer }.count
        let missing = rows.filter { $0.favouriteState == .notAcquired }.count
        var parts = [Formatting.trackCount(rows.count) + " nei preferiti"]
        if onPhone > 0 { parts.append("\(onPhone) sul telefono") }
        if onServer > 0 {
            switch server {
            case .reachable: parts.append("\(onServer) in streaming dal server")
            case .unreachable: parts.append("\(onServer) solo sul server, non raggiungibile")
            case .unknown: parts.append("\(onServer) solo sul server")
            }
        }
        if missing > 0 { parts.append("\(missing) non ancora scaricati") }
        return parts.joined(separator: " · ") + "."
    }
}

/// One favourite. The shared track row, so the long press, the swipes and the
/// problems are the same as everywhere else; what this screen chooses is the artwork
/// with its state on it, the line under the title, and a trailing slot that asks
/// where a missing track should go rather than starting a download on its own.
private struct FavouriteRow: View {
    let data: TrackRowData
    /// Read once by the screen above and handed down, so every row on this screen
    /// says the same thing about the server.
    let server: ServerState

    @Environment(AcquisitionCoordinator.self) private var acquisitions

    var body: some View {
        TrackRow(
            data: data,
            subtitle: subtitle,
            subtitleLineLimit: 2,
            choosesDestination: true
        ) {
            FavouriteArtwork(data: data, server: server)
        } trailing: {
            FavouriteStateSlot(data: data, server: server)
        }
    }

    /// The state first, then the artist, so the three kinds of row read apart at a
    /// glance and not only by their icon.
    private var subtitle: String {
        if let record = data.acquisition, record.isActive {
            return AcquisitionText.phase(of: record, pollFailures: acquisitions.pollFailures)
        }
        switch data.downloadState {
        case .queued:
            return "Sul telefono · in coda"
        case .downloading:
            return "Sul telefono · download in corso"
        case .notDownloaded, .downloaded, .failed, .cancelled:
            break
        }
        let lead = data.favouriteState == .onPhone ? nil : data.favouriteState.label(server)
        return [lead, data.artist].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The 46 pt artwork of a favourite, with what the app actually has drawn on it: a
/// full-strength cover for a track on the phone, a dimmed one with a drive badge for
/// one only the server has, and a dimmed placeholder with a dashed ring for one that
/// is nowhere yet.
///
/// A favourite with no track has no album and so no local cover, only the artwork
/// URL search returned, which is loaded the way Cerca loads its thumbnails.
private struct FavouriteArtwork: View {
    let data: TrackRowData
    let server: ServerState

    @Environment(AppSettings.self) private var settings
    @Environment(\.prismaInk) private var ink
    /// Read by nothing: the row reports its own problems, and a missing thumbnail
    /// is already visible as the placeholder. `RemoteImage` needs somewhere to put it.
    @State private var artworkError: APIError?

    private let side: CGFloat = 46

    var body: some View {
        ZStack {
            if let url = data.artworkURL, let client = artworkClient {
                RemoteImage(client: client, reference: url, side: side, failure: $artworkError)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                CoverArt(cover: data.cover, side: side, cornerRadius: 10)
            }
        }
        // Full strength for a file on this phone, nearly full for one the server
        // will stream, dim for one that nothing can play right now.
        .opacity(data.favouriteState.canPlay(server) ? (data.isOnPhone ? 1 : 0.8) : 0.5)
        .overlay(alignment: .bottomTrailing) {
            badge
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badge: some View {
        switch data.favouriteState {
        case .onPhone:
            EmptyView()
        case .onServer:
            symbol("externaldrive.fill")
        case .notAcquired:
            symbol("circle.dashed")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.95))
            .frame(width: 18, height: 18)
            .background(Color.black.opacity(0.65), in: Circle())
            .offset(x: 4, y: 4)
    }

    /// Artwork only; without a usable address the placeholder is drawn and the
    /// address problem is reported by whatever tries to use the server.
    private var artworkClient: APIClient? {
        try? settings.makeClient()
    }
}

/// The trailing slot of a favourite: the chain's progress while one runs, the
/// standard transfer icon while a device download does, and otherwise a download
/// arrow that asks where the copy should go instead of starting one.
private struct FavouriteStateSlot: View {
    let data: TrackRowData
    let server: ServerState

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(\.prismaInk) private var ink
    /// Its own sheet, by value: it is opened from this button and stays up while the
    /// row behind it changes.
    @State private var destination: AcquisitionRequest?

    var body: some View {
        content
            .sheet(item: $destination) { request in
                DestinationSheet(request: request, reason: data.favouriteState.reason(title: data.title, server: server))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let record = data.acquisition, record.isActive {
            ProgressRing(fraction: record.stage == .onServer ? record.serverProgress : nil, color: ink.accent, side: 18)
                .frame(width: 44, height: 44)
                .accessibilityLabel(AcquisitionText.phase(of: record, pollFailures: acquisitions.pollFailures))
        } else if data.isOnPhone || data.isBusy || (data.downloadState == .failed && data.presence == .inLibrary) {
            // On the phone, arriving, or a device download to retry: the icon every
            // other screen shows, doing what it does everywhere.
            TrackStateSlot(data: data)
        } else {
            Button {
                destination = data.acquisitionRequest
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ink.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Scarica: scegli dove tenerlo")
            .padding(.trailing, -10)
        }
    }
}

// MARK: - Riproduci and Casuale

/// Prototype `.acts`: Riproduci filled and Casuale in glass, side by side.
struct PlayShufflePair: View {
    let isEnabled: Bool
    let onPlay: () -> Void
    let onShuffle: () -> Void

    @Environment(\.prismaInk) private var ink

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Label("Riproduci", systemImage: "play.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ink.fillForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(ink.fillBackground, in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onShuffle) {
                Label("Casuale", systemImage: "shuffle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ink.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .prismaGlass(RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Riproduci and Casuale over a list of tracks, in the order given: the queue is
/// the downloaded ones among them. Riproduci turns shuffle off and starts at the
/// first; Casuale turns shuffle on first, so the queue is built shuffled from a
/// random one.
struct PlayShuffleButtons: View {
    let tracks: [TrackRowData]
    let sourceName: String

    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.modelContext) private var context

    var body: some View {
        // Enabled by what can play now; the engine decides again at the tap, over
        // the tracks it reads back then, so a server that went away in between
        // simply produces a shorter queue rather than a dead button.
        let playable = tracks.contains { $0.canPlay(ServerState(reachability.isReachable)) }
        // The buttons are tapped long after this body, so their closures keep the
        // ids and read the tracks back then.
        let ids = tracks.map(\.id)
        PlayShufflePair(isEnabled: playable) {
            let live = ModelLookup.tracks(ids, in: context)
            guard let first = live.firstIndex(where: { playback.canPlayNow($0) }) else { return }
            playback.setShuffle(false)
            presenter.sourceName = sourceName
            playback.play(playlistTracks: live, startingAt: first)
        } onShuffle: {
            let live = ModelLookup.tracks(ids, in: context)
            guard let start = live.indices.filter({ playback.canPlayNow(live[$0]) }).randomElement() else { return }
            playback.setShuffle(true)
            presenter.sourceName = sourceName
            playback.play(playlistTracks: live, startingAt: start)
        }
    }
}
