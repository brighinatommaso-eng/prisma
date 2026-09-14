import Foundation
import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(AppSettings.self) private var settings
    @State private var model = SearchModel()
    /// Favourites and playlists refer to tracks in the local library, so a result can
    /// only be favourited or added once its video id is in the library.
    @Query private var libraryTracks: [StoredTrack]

    var body: some View {
        List {
            Section {
                TextField("Song, artist or album", text: $model.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { model.search(settings: settings) }
                Button("Search") { model.search(settings: settings) }
            } footer: {
                Text(Formatting.serverLine(settings.savedAddress))
            }

            switch model.state {
            case .idle:
                Section {
                    Text("Type a query and tap Search.")
                }
            case .loading(let since):
                Section {
                    LoadingRow(message: "Searching…", since: since, timeout: APIClient.Timeout.search)
                }
            case .failed(let error):
                Section {
                    ErrorReport(error: error)
                }
            case .loaded(let results):
                let songs = results.response.value
                let localTracks = Dictionary(libraryTracks.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
                Section {
                    if songs.isEmpty {
                        Text("The server returned no results for “\(results.query)”.")
                    } else {
                        // Indexed rather than keyed by video_id: nothing guarantees
                        // the results contain no duplicates.
                        ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                            SongRow(song: song, client: results.client, localTrack: localTracks[song.videoID])
                        }
                    }
                } header: {
                    Text("\(songs.count) results for “\(results.query)” in \(results.response.milliseconds) ms")
                        .textCase(nil)
                }
            }
        }
        .navigationTitle("Search")
    }
}

private struct SongRow: View {
    let song: SongResult
    let client: APIClient
    let localTrack: StoredTrack?

    @State private var artworkError: APIError?
    @State private var addingToPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(client: client, reference: song.artworkURLSmall, side: 56, failure: $artworkError)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title ?? "(no title)")
                    Text(song.artist ?? "(no artist)")
                        .font(.subheadline)
                    Text(song.album ?? "(no album)")
                        .font(.subheadline)
                    Text(Formatting.duration(song.durationS))
                        .font(.caption.monospacedDigit())
                }
            }
            if let artworkError {
                Text("Artwork failed: \(artworkError.oneLine)")
                    .font(.caption2)
                    .textSelection(.enabled)
            }
            if let localTrack {
                HStack(spacing: 20) {
                    FavouriteButton(track: localTrack)
                    Button("Add to playlist…") { addingToPlaylist = true }
                }
                .buttonStyle(.borderless)
            } else {
                Text("Not in your library yet, so it cannot be favourited or added to a playlist. Once the server has it, sync the library.")
                    .font(.caption2)
            }
        }
        .sheet(isPresented: $addingToPlaylist) {
            if let localTrack {
                AddToPlaylistSheet(track: localTrack)
            }
        }
    }
}
