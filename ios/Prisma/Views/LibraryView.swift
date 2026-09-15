import Foundation
import SwiftData
import SwiftUI

/// Renders the library stored on this iPhone. Opening it makes no network call;
/// only Sync and pull-to-refresh talk to the server.
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(\.prismaInk) private var ink

    @Query private var albums: [StoredAlbum]
    @Query private var tracks: [StoredTrack]
    @Query private var records: [SyncRecord]

    @State private var confirmingFullResync = false
    @State private var filter: LibraryFilter = .albums

    var body: some View {
        List {
            FilterChips(options: LibraryFilter.allCases, selection: $filter) { $0.label }
                .padding(.top, 4)
                .prismaRow()
                .listRowSeparator(.hidden)

            switch filter {
            case .albums:
                albumsContent
            case .playlists:
                PlaylistsContent()
            case .favourites:
                FavouritesContent()
            }
        }
        .prismaList()
        .navigationTitle("Libreria")
        .toolbar {
            if filter == .playlists {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        sync.syncNow(full: false)
                    } label: {
                        Label("Sincronizza modifiche", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(sync.isSyncing)
                    Button {
                        confirmingFullResync = true
                    } label: {
                        Label("Risincronizza tutto…", systemImage: "arrow.clockwise")
                    }
                    .disabled(sync.isSyncing)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .accessibilityLabel("Sincronizzazione")
            }
        }
        .refreshable { [sync] in
            await sync.refresh()
        }
        .confirmationDialog("Risincronizza tutto", isPresented: $confirmingFullResync, titleVisibility: .visible) {
            Button("Risincronizza tutto", role: .destructive) {
                sync.syncNow(full: true)
            }
        } message: {
            Text("Scarica di nuovo l'intero catalogo. Album e brani che il server non elenca più vengono rimossi da questo iPhone, insieme ai file scaricati.")
        }
    }

    // MARK: - Albums

    @ViewBuilder
    private var albumsContent: some View {
        syncStatus

        if albums.isEmpty && tracks.isEmpty {
            Text(settings.savedAddress.isEmpty
                 ? "La libreria è vuota. Imposta l'indirizzo del server in Impostazioni, poi trascina verso il basso per sincronizzare."
                 : "La libreria è vuota. Trascina verso il basso per sincronizzare.")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
                .padding(.vertical, 16)
                .prismaRow()
                .listRowSeparator(.hidden)
        }

        ForEach(sortedAlbums) { album in
            AlbumHeaderRow(album: album)
                .prismaRow()
                .listRowSeparator(.hidden, edges: .top)
            ForEach(StoredTrack.albumOrder(album.tracks)) { track in
                TrackRow(track: track, onPlay: { play(track) }) {
                    TrackNumber(track: track)
                }
                .prismaRow()
            }
        }

        let unlisted = StoredTrack.albumOrder(tracks.filter { $0.album == nil })
        if !unlisted.isEmpty {
            SectionLabel("Brani senza album")
                .prismaRow()
                .listRowSeparator(.hidden, edges: .top)
            ForEach(unlisted) { track in
                TrackRow(track: track, onPlay: { play(track) }) {
                    TrackNumber(track: track)
                }
                .prismaRow()
            }
        }

        TechnicalDetailsSection {
            libraryDetails
        }
        .padding(.top, 12)
        .prismaRow()
        .listRowSeparator(.hidden)
    }

    private func play(_ track: StoredTrack) {
        presenter.sourceName = nil
        playback.play(track: track)
    }

    /// Only what needs attention: a sync running or failed. The rest is in the
    /// technical details.
    @ViewBuilder
    private var syncStatus: some View {
        switch sync.status {
        case .idle, .succeeded:
            EmptyView()
        case .syncing:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(ink.secondary)
                Text("Sincronizzazione in corso…")
                    .font(.footnote)
                    .foregroundStyle(ink.secondary)
            }
            .frame(minHeight: 44)
            .prismaRow()
            .listRowSeparator(.hidden)
        case .failed(let error):
            VStack(alignment: .leading, spacing: 0) {
                ProblemBlock(summary: "Sincronizzazione non riuscita: " + PlainLanguage.summary(for: error).lowercasedFirst,
                             details: .error(error))
                Text("La libreria qui sotto è quella già salvata sul telefono.")
                    .font(.caption)
                    .foregroundStyle(ink.secondary)
                    .padding(.bottom, 8)
            }
            .prismaRow()
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var libraryDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Formatting.serverLine(settings.savedAddress))
                .textSelection(.enabled)
            Text("\(albums.count) albums, \(tracks.count) tracks stored on this iPhone. \(tracks.filter { $0.downloadState == .downloaded }.count) downloaded.")
            if case .syncing(let started, let since) = sync.status {
                LoadingRow(
                    message: since.map { "Syncing changes since \($0)…" } ?? "Syncing the full catalogue…",
                    since: started,
                    timeout: APIClient.Timeout.library
                )
            }
            if case .succeeded(let date) = sync.status {
                Text("Sync succeeded at \(Formatting.time(date)).")
            }
            if let record = records.first, let lastSyncAt = record.lastSyncAt {
                FieldRow(label: "Last successful sync", value: Formatting.dateTime(lastSyncAt))
                if let summary = record.lastSummary {
                    Text(summary)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                Text("Never synced.")
            }
            ForEach(sortedAlbums.filter { $0.coverError != nil }) { album in
                if let coverError = album.coverError {
                    Text("Cover of “\(album.title)” (album id \(album.serverID)) failed:\n\(coverError)")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var sortedAlbums: [StoredAlbum] {
        albums.sorted {
            let byArtist = $0.artist.localizedStandardCompare($1.artist)
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

extension String {
    /// "Impossibile…" → "impossibile…", to follow a colon.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + String(dropFirst())
    }
}

/// Prototype `.tno`.
struct TrackNumber: View {
    let track: StoredTrack

    @Environment(\.prismaInk) private var ink

    var body: some View {
        Text(track.trackNo.map { String($0) } ?? "—")
            .font(.caption.monospacedDigit())
            .foregroundStyle(ink.secondary)
            .frame(width: 18, alignment: .leading)
    }
}

/// Prototype `.ahead`: cover 62 pt, title, artist and year. A cover that failed to
/// download or cannot be read shows a warning that reveals the error.
private struct AlbumHeaderRow: View {
    let album: StoredAlbum

    @Environment(\.prismaInk) private var ink
    @State private var coverProblem: String?
    @State private var showingCoverProblem = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                LocalCoverImage(album: album, side: 62, problem: $coverProblem)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.45), radius: 11, y: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title)
                        .font(.headline)
                        .foregroundStyle(ink.primary)
                        .lineLimit(2)
                    Text([album.artist, album.year.map { String($0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if problemText != nil {
                    Button {
                        showingCoverProblem.toggle()
                    } label: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(ink.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showingCoverProblem ? "Nascondi dettagli tecnici della copertina" : "Copertina non disponibile. Mostra dettagli tecnici")
                }
            }
            if showingCoverProblem, let problemText {
                ErrorReport(storedText: "Copertina non disponibile\n" + problemText)
                    .foregroundStyle(ink.primary)
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    private var problemText: String? {
        let parts = [album.coverError.map { "Cover download failed:\n\($0)" }, coverProblem].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
