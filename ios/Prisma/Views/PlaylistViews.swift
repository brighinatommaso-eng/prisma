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
        case .albums: return "Albums"
        case .playlists: return "Playlists"
        case .favourites: return "Favourites"
        }
    }
}

/// A heart that toggles the track's favourite flag.
struct FavouriteButton: View {
    let track: StoredTrack
    /// Icon only, with this whole area tappable (a plain button otherwise responds
    /// only on the drawn glyph). nil shows the heart with a text label.
    var iconHitSize: CGSize?

    @Environment(PlaylistStore.self) private var store

    var body: some View {
        Button {
            store.toggleFavourite(track)
        } label: {
            if let iconHitSize {
                Image(systemName: track.isFavourite ? "heart.fill" : "heart")
                    .frame(width: iconHitSize.width, height: iconHitSize.height)
                    .contentShape(Rectangle())
            } else {
                Label(track.isFavourite ? "Favourite" : "Add to favourites",
                      systemImage: track.isFavourite ? "heart.fill" : "heart")
            }
        }
        .accessibilityLabel(track.isFavourite ? "Remove from favourites" : "Add to favourites")
    }
}

/// Errors and notices from playlist actions, with a way to dismiss them.
struct PlaylistStoreMessages: View {
    @Environment(PlaylistStore.self) private var store

    var body: some View {
        if let error = store.lastError {
            ErrorReport(error: error)
            Button("Dismiss error") { store.clearError() }
        }
        if let notice = store.notice {
            Text(notice)
            Button("Dismiss") { store.clearNotice() }
        }
    }
}

// MARK: - Playlists filter

struct PlaylistsContent: View {
    @Environment(PlaylistStore.self) private var store
    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]

    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""

    var body: some View {
        Section {
            Button("New playlist…") {
                newName = ""
                creating = true
            }
            PlaylistStoreMessages()
        }
        .alert("New playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { store.createPlaylist(named: newName) }
            Button("Cancel", role: .cancel) {}
        }

        Section {
            if playlists.isEmpty {
                Text("No playlists yet.")
            }
            ForEach(playlists) { playlist in
                NavigationLink {
                    PlaylistDetailView(playlist: playlist)
                } label: {
                    PlaylistSummaryRow(playlist: playlist)
                }
                .swipeActions(edge: .trailing) {
                    Button("Delete", role: .destructive) {
                        store.delete([playlist])
                    }
                    Button("Rename") {
                        renameText = playlist.name
                        renaming = playlist
                    }
                }
            }
            .onDelete { offsets in
                store.delete(offsets.map { playlists[$0] })
            }
            .onMove { source, destination in
                store.movePlaylists(playlists, from: source, to: destination)
            }
        } header: {
            Text("Playlists").textCase(nil)
        } footer: {
            Text("Swipe a playlist to rename or delete it. Tap Edit to reorder.")
        }
        .alert("Rename playlist", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let renaming {
                    store.rename(renaming, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct PlaylistSummaryRow: View {
    let playlist: Playlist

    var body: some View {
        let entries = PlaylistStore.orderedEntries(of: playlist)
        let missing = entries.filter { $0.track?.downloadState != .downloaded }.count
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.name)
            Text("\(entries.count) track\(entries.count == 1 ? "" : "s")"
                 + (missing > 0 ? ", \(missing) not downloaded" : ""))
                .font(.caption)
        }
    }
}

// MARK: - Playlist detail

struct PlaylistDetailView: View {
    let playlist: Playlist

    @Environment(PlaylistStore.self) private var store

    @State private var renaming = false
    @State private var renameText = ""

    var body: some View {
        let entries = PlaylistStore.orderedEntries(of: playlist)
        let missingTracks = Set(entries.compactMap { entry -> String? in
            guard let track = entry.track, track.downloadState != .downloaded else { return nil }
            return track.serverID
        })
        let firstPlayable = entries.firstIndex { $0.track?.downloadState == .downloaded }

        List {
            Section {
                Text("\(entries.count) track\(entries.count == 1 ? "" : "s")"
                     + (missingTracks.isEmpty ? ", all downloaded" : ", \(missingTracks.count) not downloaded"))
                if let firstPlayable {
                    Button("Play") { store.play(playlist, fromEntryAt: firstPlayable) }
                }
                if !missingTracks.isEmpty {
                    Button("Download \(missingTracks.count) missing track\(missingTracks.count == 1 ? "" : "s")") {
                        store.downloadMissing(in: playlist)
                    }
                }
                Button("Rename…") {
                    renameText = playlist.name
                    renaming = true
                }
                PlaylistStoreMessages()
            }

            Section {
                if entries.isEmpty {
                    Text("This playlist is empty. Add tracks from Library or Search.")
                }
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    PlaylistEntryRow(playlist: playlist, entry: entry, index: index)
                }
                .onDelete { offsets in
                    store.remove(offsets.map { entries[$0] }, from: playlist)
                }
                .onMove { source, destination in
                    store.moveEntries(in: playlist, ordered: entries, from: source, to: destination)
                }
            } header: {
                Text("Tracks").textCase(nil)
            } footer: {
                Text("Swipe a track to remove it. Tap Edit to reorder.")
            }
        }
        .navigationTitle(playlist.name)
        .toolbar {
            EditButton()
        }
        .alert("Rename playlist", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { store.rename(playlist, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        // Pushed inside a tab, so it needs the mini player inset itself.
        .miniPlayerInset()
    }
}

private struct PlaylistEntryRow: View {
    let playlist: Playlist
    let entry: PlaylistEntry
    let index: Int

    @Environment(PlaylistStore.self) private var store
    @Environment(PlaybackEngine.self) private var playback

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(index + 1)")
                .font(.body.monospacedDigit())
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if let track = entry.track {
                    if track.downloadState == .downloaded {
                        Button {
                            store.play(playlist, fromEntryAt: index)
                        } label: {
                            Label(track.title ?? "(no title)", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Text(track.title ?? "(no title)")
                        Text("Not downloaded. Download to play.")
                            .font(.caption)
                    }
                    Text([track.album?.artist, track.album?.title].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                    Text(Formatting.duration(track.durationS))
                        .font(.caption)
                    FavouriteButton(track: track)
                        .buttonStyle(.borderless)
                    TrackDownloadStatus(track: track)
                } else {
                    Text("This track is no longer in the library.")
                    Button("Remove from playlist") {
                        store.remove([entry], from: playlist)
                    }
                    .buttonStyle(.borderless)
                }
            }
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
                    Text(track.title ?? track.serverID)
                    if let album = track.album {
                        Text("\(album.artist) · \(album.title)")
                            .font(.caption)
                    }
                }

                Section {
                    TextField("Playlist name", text: $newName)
                    Button("Create and add") {
                        if let playlist = store.createPlaylist(named: newName) {
                            store.add(track, to: playlist)
                            dismiss()
                        }
                    }
                } header: {
                    Text("New playlist").textCase(nil)
                }

                Section {
                    if playlists.isEmpty {
                        Text("No playlists yet.")
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
                                Text("\(entries.count) track\(entries.count == 1 ? "" : "s")"
                                     + (contains ? ". Already contains this track; it will be added again." : ""))
                                    .font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("Add to").textCase(nil)
                }

                if store.lastError != nil {
                    Section {
                        PlaylistStoreMessages()
                    }
                }
            }
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Favourites filter

struct FavouritesContent: View {
    @Query private var tracks: [StoredTrack]

    var body: some View {
        let favourites = tracks
            .filter { $0.favouritedAt != nil }
            .sorted { ($0.favouritedAt ?? .distantPast) > ($1.favouritedAt ?? .distantPast) }
        Section {
            if favourites.isEmpty {
                Text("No favourites yet. Tap the heart on any track.")
            }
            ForEach(favourites) { track in
                FavouriteTrackRow(track: track)
            }
        } header: {
            Text("Favourites, most recent first").textCase(nil)
        }
    }
}

private struct FavouriteTrackRow: View {
    let track: StoredTrack

    @Environment(PlaybackEngine.self) private var playback
    @State private var addingToPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if track.downloadState == .downloaded {
                Button {
                    playback.play(track: track)
                } label: {
                    Label(track.title ?? "(no title)", systemImage: "play.fill")
                }
                .buttonStyle(.borderless)
            } else {
                Text(track.title ?? "(no title)")
                Text("Download to play.")
                    .font(.caption)
            }
            Text([track.album?.artist, track.album?.title].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
            HStack(spacing: 20) {
                FavouriteButton(track: track)
                Button("Add to playlist…") { addingToPlaylist = true }
            }
            .buttonStyle(.borderless)
            TrackDownloadStatus(track: track)
        }
        .sheet(isPresented: $addingToPlaylist) {
            AddToPlaylistSheet(track: track)
        }
    }
}
