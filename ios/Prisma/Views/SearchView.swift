import Foundation
import SwiftUI

struct SearchView: View {
    @Environment(AppSettings.self) private var settings
    @State private var model = SearchModel()

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
                Section {
                    if songs.isEmpty {
                        Text("The server returned no results for “\(results.query)”.")
                    } else {
                        // Indexed rather than keyed by video_id: nothing guarantees
                        // the results contain no duplicates.
                        ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                            SongRow(song: song, client: results.client)
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

    @State private var artworkError: APIError?

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
        }
    }
}
