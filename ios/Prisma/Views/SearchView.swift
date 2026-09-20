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
    /// Results already being acquired, so a second tap cannot queue them again.
    @Query private var acquisitions: [PendingAcquisition]

    var body: some View {
        // The one place this screen reads the store.
        let index = Projection.search(tracks: libraryTracks, acquisitions: acquisitions)

        List {
            SearchField(query: $model.query) {
                model.search(settings: settings)
            }
            .padding(.top, 4)
            .padding(.bottom, 10)
            .prismaRow()
            .listRowSeparator(.hidden)

            AcquisitionCoordinatorError()
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
                ProblemBlock("La ricerca non è riuscita. " + PlainLanguage.message(for: error))
                    .prismaRow()
                    .listRowSeparator(.hidden)
            case .loaded(let results):
                let songs = results.response.value
                if songs.isEmpty {
                    message("Nessun risultato per “\(results.query)”.")
                } else {
                    // Indexed rather than keyed by video_id: nothing guarantees
                    // the results contain no duplicates.
                    ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                        SongRow(song: song, client: results.client, localTrack: index.tracks[song.videoID], pending: index.acquisitions[song.videoID])
                            .prismaRow()
                    }
                }
            }
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

/// A search result. Holds no `@State`: the one piece this row used to own, whether
/// its thumbnail failed, now belongs to the thumbnail itself.
///
/// That matters because `localTrack` is a library row, and `RemoteImage` reports a
/// failure whenever the network answers — unattended, with nothing else changing.
/// A row that rendered again for that reason would rebuild `TrackRow` around a track
/// the sync may have deleted in the meantime, which is the shape that crashed build
/// 25 in `LocalCoverImage`. Nothing here renders again on its own any more.
private struct SongRow: View {
    let song: SongResult
    let client: APIClient
    let localTrack: TrackRowData?
    let pending: AcquisitionData?

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(\.prismaInk) private var ink

    var body: some View {
        let subtitle = [song.artist, song.album].compactMap { $0 }.joined(separator: " · ")
        if let localTrack {
            // In the library: the shared track row, so a result already on the phone
            // plays on tap and one that is not starts its device download.
            TrackRow(data: localTrack, subtitle: subtitle) {
                thumbnail
            }
        } else {
            // Not in the library: tapping acquires it through the server, and never
            // plays. No long-press menu: every item acts on a library track.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        acquisitions.acquire(song)
                    } label: {
                        HStack(spacing: 13) {
                            thumbnail
                            VStack(alignment: .leading, spacing: 1) {
                                Text(song.title ?? "Senza titolo")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(ink.primary)
                                    .lineLimit(1)
                                Text(pending.map { AcquisitionText.phase(of: $0, pollFailures: acquisitions.pollFailures) } ?? subtitle)
                                    .font(.caption)
                                    .foregroundStyle(ink.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(Formatting.trackTime(song.durationS))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ink.secondary)
                        }
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Not disabled while pending, which would dim the row; acquire()
                    // ignores a track already being acquired.
                    .accessibilityHint(pending == nil ? "Scarica il brano sul server e poi sul telefono" : "")

                    AcquisitionStateIcon(song: song, record: pending)
                        .padding(.trailing, -10)
                }
                if let pending, pending.stage == .failed {
                    AcquisitionProblem(record: pending)
                }
            }
        }
    }

    private var thumbnail: some View {
        SearchThumbnail(client: client, reference: song.artworkURLSmall)
    }
}

/// Prototype `.rthumb`: 46 pt, radius 10, with what went wrong with the image under
/// it.
///
/// The artwork failure lives here, at the bottom of the row rather than at the top,
/// because `RemoteImage` writes it from its own `.task`: whenever the network
/// answers, with no parent involved and nothing else invalidated. A view that
/// renders again for that reason must hold nothing from the store, and this one
/// holds a client and a URL string.
///
/// That is why the message appears in the thumbnail's column instead of across the
/// row: the row above holds a library track, so it cannot be the one to own the
/// failure and print it.
private struct SearchThumbnail: View {
    let client: APIClient
    let reference: String?

    @State private var failure: APIError?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(client: client, reference: reference, side: 46, failure: $failure)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if let problem {
                ProblemBlock(error: problem)
            }
        }
        .padding(.vertical, 8)
    }

    /// Search artwork comes from YouTube's image servers, not the Prisma backend, so a
    /// failure is about the internet connection rather than the server address.
    private var problem: APIError? {
        guard let failure else { return nil }
        var problem = failure
        problem.message = failure.kind == .transport
            ? "La copertina di questo risultato non si è caricata: controlla la connessione a internet. Il brano si può comunque scaricare."
            : "La copertina di questo risultato non è un'immagine valida: il brano si può comunque scaricare."
        return problem
    }
}
