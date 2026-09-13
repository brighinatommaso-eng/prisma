import Foundation
import SwiftUI

struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @State private var model = LibraryModel()

    var body: some View {
        // Every state renders inside the List, so pull-to-refresh is available
        // on the error screen too.
        List {
            Section {
                Text("Pull down to reload.")
            } footer: {
                Text(Formatting.serverLine(settings.savedAddress))
            }

            switch model.state {
            case .idle:
                Section {
                    Text("Not loaded yet.")
                }
            case .loading(let since):
                Section {
                    LoadingRow(message: "Loading /library…", since: since, timeout: APIClient.Timeout.library)
                }
            case .failed(let error):
                Section {
                    ErrorReport(error: error)
                }
            case .loaded(let loaded):
                let library = loaded.response.value
                let trackCount = library.albums.reduce(0) { $0 + $1.tracks.count }
                Section {
                    Text("\(library.albums.count) albums, \(trackCount) tracks. HTTP \(loaded.response.status) in \(loaded.response.milliseconds) ms, at \(loaded.response.receivedAt.formatted(date: .omitted, time: .standard)).")
                }
                if library.albums.isEmpty {
                    Section {
                        Text("The server's library is empty.")
                    }
                }
                ForEach(library.albums) { album in
                    Section {
                        AlbumRow(album: album, client: loaded.client)
                        if album.tracks.isEmpty {
                            Text("No tracks in this album.")
                        }
                        ForEach(album.tracks) { track in
                            TrackRow(track: track)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .refreshable { [model, settings] in
            await model.refresh(settings: settings)
        }
        .onAppear {
            model.loadIfNeeded(settings: settings)
        }
    }
}

private struct AlbumRow: View {
    let album: LibraryAlbum
    let client: APIClient

    @State private var coverError: APIError?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(client: client, reference: album.coverURL, side: 100, failure: $coverError)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.headline)
                    Text(album.artist)
                    Text(album.year.map { String($0) } ?? "year unknown")
                        .font(.subheadline)
                    Text("\(album.tracks.count) tracks, album id \(album.id)")
                        .font(.caption)
                }
            }
            if album.coverURL == nil {
                Text("The server sent no cover_url for this album.")
                    .font(.caption2)
            }
            if let coverError {
                Text("Cover failed: \(coverError.oneLine)")
                    .font(.caption2)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct TrackRow: View {
    let track: LibraryTrack

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(track.trackNo.map { String($0) } ?? "–")
                .font(.body.monospacedDigit())
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title ?? "(no title)")
                Text("\(Formatting.duration(track.durationS)), \(Formatting.bytes(track.fileBytes))")
                    .font(.caption)
            }
        }
    }
}
