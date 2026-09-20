import Foundation
import SwiftData
import SwiftUI

/// The Library tab: Preferiti and Playlist. Opening it makes no network call; only
/// Sync and pull-to-refresh talk to the server.
///
/// There is no album screen any more. Albums are still stored, and still supply the
/// cover and the artist name a row shows, but the collection the user browses is
/// Preferiti, which is a flat list of tracks and can hold one the server has never
/// heard of.
///
/// This screen reads the store only for the sync record; both filters read what they
/// need themselves, each in one place (see `Projection`).
struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibrarySync.self) private var sync
    @Environment(\.prismaInk) private var ink

    @Query private var records: [SyncRecord]

    @State private var confirmingFullResync = false
    @State private var filter: LibraryFilter = .favourites
    /// Owned here rather than by the system EditButton, whose labels would follow the
    /// app's English development region.
    @State private var editMode: EditMode = .inactive

    var body: some View {
        // The one place this screen reads the store.
        let lastSyncAt = records.first?.lastSyncAt

        List {
            FilterChips(options: LibraryFilter.allCases, selection: $filter) { $0.label }
                .padding(.top, 4)
                .prismaRow()
                .listRowSeparator(.hidden)

            syncStatus

            switch filter {
            case .favourites:
                FavouritesContent()
            case .playlists:
                PlaylistsContent()
            }

            Text(lastSyncLine(lastSyncAt))
                .font(.caption)
                .foregroundStyle(ink.secondary)
                .padding(.top, 20)
                .padding(.bottom, 12)
                .prismaRow()
                .listRowSeparator(.hidden)
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
            Text("Scarica di nuovo l'intero catalogo. Brani che il server non elenca più vengono rimossi da questo iPhone, insieme ai file scaricati — tranne quelli di cui questo telefono ha chiesto l'unica copia, che restano. I preferiti non si perdono mai: un brano rimosso resta nell'elenco e si può riscaricare.")
        }
    }

    /// Only what needs attention: a sync running or failed, and an address that has
    /// never been set.
    @ViewBuilder
    private var syncStatus: some View {
        switch sync.status {
        case .idle, .succeeded:
            if settings.savedAddress.isEmpty {
                Text("Nessun indirizzo del server impostato: impostalo in Impostazioni per cercare e scaricare brani.")
                    .font(.subheadline)
                    .foregroundStyle(ink.secondary)
                    .padding(.vertical, 12)
                    .prismaRow()
                    .listRowSeparator(.hidden)
            }
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
