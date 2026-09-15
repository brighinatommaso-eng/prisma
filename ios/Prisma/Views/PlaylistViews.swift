import Foundation
import SwiftData
import SwiftUI

/// Library filters. Playlists and Favourites live inside the Library tab rather than
/// in a fifth tab.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case albums
    case playlists
    case favourites

    var id: String { rawValue }

    var label: String {
        switch self {
        case .albums: return "Album"
        case .playlists: return "Playlist"
        case .favourites: return "Preferiti"
        }
    }
}

/// A heart that toggles the track's favourite flag, with the whole `hitSize` area
/// tappable (a plain button otherwise responds only on the drawn glyph).
struct FavouriteButton: View {
    let track: StoredTrack
    var hitSize = CGSize(width: 44, height: 44)
    var glyphSize: CGFloat = 19

    @Environment(PlaylistStore.self) private var store
    @Environment(\.prismaInk) private var ink

    var body: some View {
        Button {
            store.toggleFavourite(track)
        } label: {
            Image(systemName: track.isFavourite ? "heart.fill" : "heart")
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(track.isFavourite ? ink.favourite : ink.secondary)
                .frame(width: hitSize.width, height: hitSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(track.isFavourite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")
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
    @Environment(\.prismaInk) private var ink
    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]

    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""

    var body: some View {
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
                if let renaming {
                    store.rename(renaming, to: renameText)
                }
            }
            Button("Annulla", role: .cancel) {}
        }

        PlaylistStoreMessages()

        if playlists.isEmpty {
            Text("Nessuna playlist. Tocca Nuova playlist per crearne una.")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
                .padding(.vertical, 12)
                .prismaRow()
        }

        ForEach(playlists) { playlist in
            NavigationLink {
                PlaylistDetailView(playlist: playlist)
            } label: {
                PlaylistSummaryRow(playlist: playlist)
            }
            .swipeActions(edge: .trailing) {
                Button("Elimina", role: .destructive) {
                    store.delete([playlist])
                }
                Button("Rinomina") {
                    renameText = playlist.name
                    renaming = playlist
                }
            }
            .prismaRow()
        }
        // No onDelete: its edit-mode button would read "Delete". Swipe offers Elimina.
        .onMove { source, destination in
            store.movePlaylists(playlists, from: source, to: destination)
        }
    }
}

private struct PlaylistSummaryRow: View {
    let playlist: Playlist

    @Environment(\.prismaInk) private var ink

    var body: some View {
        let tracks = PlaylistStore.orderedEntries(of: playlist).compactMap(\.track)
        HStack(spacing: 13) {
            PlaylistMosaic(playlist: playlist, side: 62, cornerRadius: 14)
                .shadow(color: .black.opacity(0.45), radius: 11, y: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.headline)
                    .foregroundStyle(ink.primary)
                    .lineLimit(2)
                Text(Formatting.trackSummary(tracks))
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
    let playlist: Playlist

    @Environment(PlaylistStore.self) private var store
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(\.prismaInk) private var ink

    @State private var renaming = false
    @State private var renameText = ""
    @State private var editMode: EditMode = .inactive

    var body: some View {
        let entries = PlaylistStore.orderedEntries(of: playlist)
        let missingCount = Set(entries.compactMap { entry -> String? in
            guard let track = entry.track, track.downloadState != .downloaded else { return nil }
            return track.serverID
        }).count
        let playable = entries.indices.filter { entries[$0].track?.downloadState == .downloaded }

        List {
            header(entries: entries, playable: playable)
                .prismaRow()
                .listRowSeparator(.hidden, edges: .top)

            PlaylistStoreMessages()

            if entries.isEmpty {
                Text("Questa playlist è vuota. Aggiungi brani da Libreria o Cerca tenendo premuto su un brano.")
                    .font(.subheadline)
                    .foregroundStyle(ink.secondary)
                    .padding(.vertical, 12)
                    .prismaRow()
            }

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                Group {
                    if let track = entry.track {
                        TrackRow(track: track, subtitle: track.album?.artist, onPlay: {
                            presenter.sourceName = playlist.name
                            store.play(playlist, fromEntryAt: index)
                        }) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ink.secondary)
                                .frame(width: 18, alignment: .leading)
                        }
                    } else {
                        MissingEntryRow(playlist: playlist, entry: entry)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Rimuovi", role: .destructive) {
                        store.remove([entry], from: playlist)
                    }
                }
                .prismaRow()
            }
            .onMove { source, destination in
                store.moveEntries(in: playlist, ordered: entries, from: source, to: destination)
            }

            if missingCount > 0 {
                Button {
                    store.downloadMissing(in: playlist)
                } label: {
                    Text(missingCount == 1 ? "Scarica 1 brano mancante" : "Scarica \(missingCount) brani mancanti")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ink.accentText)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .prismaRow()
            }
        }
        .prismaList()
        .environment(\.editMode, $editMode)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditModeButton(editMode: $editMode)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        renameText = playlist.name
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
            Button("Rinomina") { store.rename(playlist, to: renameText) }
            Button("Annulla", role: .cancel) {}
        }
        // Pushed inside a tab, so it needs the mini player inset itself.
        .miniPlayerInset()
        .themedScreenBackground()
    }

    /// Mosaic, name, "N brani · N min", then Riproduci and Casuale side by side.
    private func header(entries: [PlaylistEntry], playable: [Int]) -> some View {
        VStack(spacing: 0) {
            PlaylistMosaic(playlist: playlist, side: 160, cornerRadius: 20)
                .shadow(color: .black.opacity(0.6), radius: 23, y: 18)
                .padding(.top, 20)
            Text(playlist.name)
                .font(.title.weight(.heavy))
                .foregroundStyle(ink.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
            Text(Formatting.trackSummary(entries.compactMap(\.track)))
                .font(.footnote)
                .foregroundStyle(ink.secondary)
                .padding(.top, 5)

            PlayShufflePair(isEnabled: !playable.isEmpty) {
                guard let first = playable.first else { return }
                // Riproduci plays in playlist order, even if shuffle was left on.
                playback.setShuffle(false)
                presenter.sourceName = playlist.name
                store.play(playlist, fromEntryAt: first)
            } onShuffle: {
                // Starts shuffled: shuffle on first, so the new queue is built
                // shuffled from a random downloaded entry.
                guard let start = playable.randomElement() else { return }
                playback.setShuffle(true)
                presenter.sourceName = playlist.name
                store.play(playlist, fromEntryAt: start)
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 22)
    }
}

/// An entry whose track has left the library.
private struct MissingEntryRow: View {
    let playlist: Playlist
    let entry: PlaylistEntry

    @Environment(PlaylistStore.self) private var store
    @Environment(\.prismaInk) private var ink

    var body: some View {
        HStack {
            Text("Brano non più in libreria")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
            Spacer(minLength: 0)
            Button {
                store.remove([entry], from: playlist)
            } label: {
                Text("Rimuovi")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ink.accentText)
                    .frame(minWidth: 44, minHeight: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Add to playlist

/// Adds a track to a playlist. A track may be added to the same playlist again.
struct AddToPlaylistSheet: View {
    let track: StoredTrack

    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]

    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(track.title ?? "Senza titolo")
                    if let album = track.album {
                        Text("\(album.artist) · \(album.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("Nome della playlist", text: $newName)
                    Button("Crea e aggiungi") {
                        if let playlist = store.createPlaylist(named: newName) {
                            store.add(track, to: playlist)
                            dismiss()
                        }
                    }
                } header: {
                    Text("Nuova playlist").textCase(nil)
                }

                Section {
                    if playlists.isEmpty {
                        Text("Nessuna playlist.")
                    }
                    ForEach(playlists) { playlist in
                        Button {
                            store.add(track, to: playlist)
                            dismiss()
                        } label: {
                            let entries = PlaylistStore.orderedEntries(of: playlist)
                            let contains = entries.contains { $0.track === track }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name)
                                Text(Formatting.trackCount(entries.count)
                                     + (contains ? " · contiene già questo brano, verrà aggiunto di nuovo" : ""))
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
            .navigationTitle("Aggiungi a playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Favourites filter

struct FavouritesContent: View {
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(\.prismaInk) private var ink
    @Query private var tracks: [StoredTrack]

    var body: some View {
        let favourites = tracks
            .filter { $0.favouritedAt != nil }
            .sorted { ($0.favouritedAt ?? .distantPast) > ($1.favouritedAt ?? .distantPast) }

        if !favourites.isEmpty {
            PlayShuffleButtons(tracks: favourites, sourceName: "Preferiti")
                .padding(.top, 12)
                .padding(.bottom, 6)
                .prismaRow()
                .listRowSeparator(.hidden)
        }

        if favourites.isEmpty {
            Text("Nessun preferito. Scorri verso destra su un brano, oppure tienilo premuto, per aggiungerlo.")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
                .padding(.vertical, 16)
                .prismaRow()
                .listRowSeparator(.hidden)
        }

        ForEach(favourites) { track in
            TrackRow(track: track, subtitle: track.album?.artist, onPlay: {
                presenter.sourceName = nil
                playback.play(track: track)
            }) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(ink.favourite)
                    .frame(width: 18)
                    .accessibilityLabel("Preferito")
            }
            .prismaRow()
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
    let tracks: [StoredTrack]
    let sourceName: String

    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter

    var body: some View {
        let playable = tracks.indices.filter { tracks[$0].downloadState == .downloaded }
        PlayShufflePair(isEnabled: !playable.isEmpty) {
            guard let first = playable.first else { return }
            playback.setShuffle(false)
            presenter.sourceName = sourceName
            playback.play(playlistTracks: tracks, startingAt: first)
        } onShuffle: {
            guard let start = playable.randomElement() else { return }
            playback.setShuffle(true)
            presenter.sourceName = sourceName
            playback.play(playlistTracks: tracks, startingAt: start)
        }
    }
}
