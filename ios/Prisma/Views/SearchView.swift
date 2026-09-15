import Foundation
import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.prismaInk) private var ink
    @State private var model = SearchModel()
    /// Favourites, playlists and downloads refer to tracks in the local library, so
    /// a result offers them only once its video id is in the library.
    @Query private var libraryTracks: [StoredTrack]

    var body: some View {
        List {
            SearchField(query: $model.query) {
                model.search(settings: settings)
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .prismaRow()
            .listRowSeparator(.hidden)

            switch model.state {
            case .idle:
                message("Cerca un brano, un artista o un album.")
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(ink.secondary)
                    Text("Ricerca in corso…")
                        .font(.footnote)
                        .foregroundStyle(ink.secondary)
                }
                .frame(minHeight: 44)
                .prismaRow()
                .listRowSeparator(.hidden)
            case .failed(let error):
                ProblemBlock(summary: "Ricerca non riuscita: " + PlainLanguage.summary(for: error).lowercasedFirst,
                             details: .error(error))
                    .prismaRow()
                    .listRowSeparator(.hidden)
            case .loaded(let results):
                let songs = results.response.value
                let localTracks = Dictionary(libraryTracks.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
                if songs.isEmpty {
                    message("Nessun risultato per “\(results.query)”.")
                } else {
                    // Indexed rather than keyed by video_id: nothing guarantees
                    // the results contain no duplicates.
                    ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                        SongRow(song: song, client: results.client, localTrack: localTracks[song.videoID])
                            .prismaRow()
                    }
                }
            }

            TechnicalDetailsSection {
                searchDetails
            }
            .padding(.top, 12)
            .prismaRow()
            .listRowSeparator(.hidden)
        }
        .prismaList()
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Cerca")
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(ink.secondary)
            .padding(.vertical, 12)
            .prismaRow()
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var searchDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Formatting.serverLine(settings.savedAddress))
                .textSelection(.enabled)
            switch model.state {
            case .idle:
                Text("No search yet.")
            case .loading(let since):
                LoadingRow(message: "Searching…", since: since, timeout: APIClient.Timeout.search)
            case .failed(let error):
                Text(error.fullText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            case .loaded(let results):
                Text("\(results.response.value.count) results for “\(results.query)” in \(results.response.milliseconds) ms")
            }
        }
    }
}

/// Prototype `.sfield`: a glass capsule with the magnifier. Searches on Return.
private struct SearchField: View {
    @Binding var query: String
    let onSubmit: () -> Void

    @Environment(\.prismaInk) private var ink

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(ink.secondary)
                .accessibilityHidden(true)
            TextField("Brano, artista o album", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .foregroundStyle(ink.primary)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ink.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancella la ricerca")
            }
        }
        .font(.subheadline)
        .padding(.leading, 16)
        .padding(.trailing, query.isEmpty ? 16 : 2)
        .frame(height: 46)
        .prismaGlass(Capsule())
    }
}

private struct SongRow: View {
    let song: SongResult
    let client: APIClient
    let localTrack: StoredTrack?

    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(\.prismaInk) private var ink
    @State private var artworkError: APIError?

    var body: some View {
        let subtitle = [song.artist, song.album].compactMap { $0 }.joined(separator: " · ")
        if let localTrack {
            TrackRow(track: localTrack, subtitle: subtitle, extraProblem: artworkError, onPlay: {
                presenter.sourceName = nil
                playback.play(track: localTrack)
            }) {
                thumbnail
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 13) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title ?? "Senza titolo")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ink.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(ink.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(Formatting.trackTime(song.durationS))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ink.secondary)
                        .padding(.trailing, 10)
                }
                .frame(minHeight: 62)
                if let artworkError {
                    ProblemBlock(error: artworkError)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Non ancora nella libreria: non si può scaricare, aggiungere ai preferiti o a una playlist finché il server non lo ha e la libreria non è sincronizzata.")
            .contextMenu {
                Text("Non ancora nella libreria. Quando il server lo avrà, sincronizza la libreria per scaricarlo o aggiungerlo a una playlist.")
            }
        }
    }

    /// Prototype `.rthumb`: 46 pt, radius 10.
    private var thumbnail: some View {
        RemoteImage(client: client, reference: song.artworkURLSmall, side: 46, failure: $artworkError)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.vertical, 8)
    }
}
