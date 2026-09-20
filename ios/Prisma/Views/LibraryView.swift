import Foundation
import SwiftData
import SwiftUI

/// Renders the library stored on this iPhone. Opening it makes no network call;
/// only Sync and pull-to-refresh talk to the server.
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(\.prismaInk) private var ink

    @Query private var albums: [StoredAlbum]
    @Query private var tracks: [StoredTrack]
    @Query private var records: [SyncRecord]

    @State private var confirmingFullResync = false
    @State private var filter: LibraryFilter = .albums
    /// Owned here rather than by the system EditButton, whose labels would follow the
    /// app's English development region.
    @State private var editMode: EditMode = .inactive

    var body: some View {
        // The one place this screen reads the store. Everything below is values.
        let data = Projection.library(albums: albums, tracks: tracks, records: records)

        List {
            FilterChips(options: LibraryFilter.allCases, selection: $filter) { $0.label }
                .padding(.top, 4)
                .prismaRow()
                .listRowSeparator(.hidden)

            switch filter {
            case .albums:
                albumsContent(data)
            case .playlists:
                PlaylistsContent()
            case .favourites:
                FavouritesContent()
            }
        }
        .prismaList()
        .environment(\.editMode, $editMode)
        .navigationTitle("Libreria")
        .toolbar {
            if filter == .playlists {
                ToolbarItem(placement: .topBarTrailing) {
                    EditModeButton(editMode: $editMode)
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
        .onChange(of: filter) { _, newFilter in
            if newFilter != .playlists {
                editMode = .inactive
            }
        }
        .refreshable { [sync] in
            await sync.refresh()
        }
        .confirmationDialog("Risincronizza tutto", isPresented: $confirmingFullResync, titleVisibility: .visible) {
            Button("Risincronizza tutto", role: .destructive) {
                sync.syncNow(full: true)
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Scarica di nuovo l'intero catalogo. Album e brani che il server non elenca più vengono rimossi da questo iPhone, insieme ai file scaricati.")
        }
    }

    // MARK: - Albums

    @ViewBuilder
    private func albumsContent(_ data: LibraryData) -> some View {
        let listed = data.listed

        if !listed.isEmpty {
            PlayShuffleButtons(tracks: listed, sourceName: "Libreria")
                .padding(.top, 12)
                .padding(.bottom, 6)
                .prismaRow()
                .listRowSeparator(.hidden)
        }

        syncStatus

        if data.isEmpty {
            Text(settings.savedAddress.isEmpty
                 ? "La libreria è vuota. Imposta l'indirizzo del server in Impostazioni, poi trascina verso il basso per sincronizzare."
                 : "La libreria è vuota. Trascina verso il basso per sincronizzare, oppure cerca un brano in Cerca.")
                .font(.subheadline)
                .foregroundStyle(ink.secondary)
                .padding(.vertical, 16)
                .prismaRow()
                .listRowSeparator(.hidden)
        }

        ForEach(data.shelves) { shelf in
            AlbumHeaderRow(heading: shelf.heading, tracks: shelf.tracks)
                .prismaRow()
                .listRowSeparator(.hidden, edges: .top)
            ForEach(shelf.tracks) { track in
                TrackRow(data: track) {
                    EmptyView()
                }
                .prismaRow()
            }
        }

        if !data.unlisted.isEmpty {
            SectionLabel("Brani senza album")
                .prismaRow()
                .listRowSeparator(.hidden, edges: .top)
            ForEach(data.unlisted) { track in
                TrackRow(data: track) {
                    EmptyView()
                }
                .prismaRow()
            }
        }

        Text(lastSyncLine(data.lastSyncAt))
            .font(.caption)
            .foregroundStyle(ink.secondary)
            .padding(.top, 20)
            .padding(.bottom, 12)
            .prismaRow()
            .listRowSeparator(.hidden)
    }

    /// Only what needs attention: a sync running or failed.
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
            ProblemBlock("La sincronizzazione della libreria non è riuscita, quindi vedi quella già salvata sul telefono. " + PlainLanguage.message(for: error))
                .prismaRow()
                .listRowSeparator(.hidden)
        }
    }

    private func lastSyncLine(_ lastSyncAt: Date?) -> String {
        guard let lastSyncAt else {
            return "Mai sincronizzata: trascina verso il basso per scaricare il catalogo dal server."
        }
        return "Ultima sincronizzazione: " + lastSyncAt.formatted(date: .abbreviated, time: .shortened) + "."
    }
}

extension String {
    /// "Impossibile…" → "impossibile…", to follow a colon.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + String(dropFirst())
    }
}

/// "Modifica" / "Fine" for a list that reorders, driving the list's own edit mode.
struct EditModeButton: View {
    @Binding var editMode: EditMode

    var body: some View {
        Button(editMode.isEditing ? "Fine" : "Modifica") {
            withAnimation {
                editMode = editMode.isEditing ? .inactive : .active
            }
        }
    }
}

/// Prototype `.ahead`: cover 62 pt, title, artist and year. A cover that failed to
/// download or cannot be read says so under the header. Long press offers the
/// album-wide actions of `CollectionMenu`.
private struct AlbumHeaderRow: View {
    let heading: AlbumHeading
    /// The album's tracks, for the header menu. See `CollectionMenu`.
    let tracks: [TrackRowData]

    @Environment(\.prismaInk) private var ink
    @State private var coverProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                LocalCoverImage(cover: heading.cover, side: 62, problem: $coverProblem)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.45), radius: 11, y: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text(heading.title)
                        .font(.headline)
                        .foregroundStyle(ink.primary)
                        .lineLimit(2)
                    Text([heading.artist, heading.year.map { String($0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if let problem = problemText {
                ProblemBlock(problem)
            }
        }
        .modifier(CollectionMenu(tracks: tracks, name: heading.title, problemKey: "album-\(heading.id)"))
        .padding(.top, 22)
        .padding(.bottom, 4)
    }

    private var problemText: String? {
        if let coverProblem {
            return coverProblem
        }
        if heading.coverFailed {
            return "La copertina di questo album non è stata scaricata: viene ritentata a ogni sincronizzazione; se resta così, controlla che il server abbia la copertina."
        }
        return nil
    }
}
