import Foundation
import SwiftData
import SwiftUI

/// Where the + on a playlist takes tracks from. Each opens its own sheet.
enum AddTrackSource: String, CaseIterable, Identifiable {
    /// The collection, several at a time: `AddFavouritesToPlaylistSheet`.
    case favourites
    /// The Cerca screen itself, presented over the playlist: `PlaylistSearchSheet`.
    case search

    var id: String { rawValue }

    var label: String {
        switch self {
        case .favourites: return "Dai preferiti"
        case .search: return "Cerca"
        }
    }

    var symbol: String {
        switch self {
        case .favourites: return "heart"
        case .search: return "magnifyingglass"
        }
    }
}

/// Dai preferiti: filling a playlist from the collection, the other way round from
/// `AddToPlaylistSheet`, several tracks at a time.
///
/// Goes through `PlaylistStore.add(_:to:)` with `FavouriteDraft`s, the shape a
/// favourite shares with a search result, so a track picked here and one added from
/// Cerca over the playlist land in it the same way.
///
/// The sheet is opened by id and resolves the playlist itself, so the screen behind
/// it can change — or the playlist be deleted — while it is up. It reads the store
/// in exactly one place, at the top of its body, and everything below that is
/// values.
///
/// It follows the plain system styling of the sheets it sits beside
/// (`AddToPlaylistSheet`, `DestinationSheet`) rather than the themed list of a tab.
struct AddFavouritesToPlaylistSheet: View {
    /// By id: this sheet outlives the row that opened it.
    let playlistID: UUID

    @Environment(PlaylistStore.self) private var store
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]
    @Query private var entries: [PlaylistEntry]
    @Query private var favourites: [FavouriteTrack]
    @Query private var tracks: [StoredTrack]

    /// The video ids picked, **in the order they were picked**: that is the order
    /// they are added in, and the reason this is an array.
    @State private var picked: [String] = []

    var body: some View {
        // The one place this sheet reads the store.
        let data = Projection.playlistAddition(
            playlistID: playlistID,
            playlists: playlists,
            entries: entries,
            favourites: favourites,
            tracks: tracks
        )

        NavigationStack {
            List {
                if data.playlistName == nil {
                    Section {
                        Text("Questa playlist non esiste più, quindi non si possono aggiungere brani.")
                    }
                } else {
                    if let error = store.lastError {
                        Section {
                            ProblemBlock(error: error)
                            Button("Chiudi") { store.clearError() }
                        }
                    }
                    content(data)
                }
            }
            .navigationTitle(data.playlistName.map { "Aggiungi a “\($0)”" } ?? "Aggiungi brani")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Aggiungi" : "Aggiungi (\(picked.count))") {
                        add(picked, from: data)
                        dismiss()
                    }
                    .disabled(picked.isEmpty || data.playlistName == nil)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ data: PlaylistAdditionData) -> some View {
        let server = ServerState(reachability.isReachable)

        Section {
            if data.rows.isEmpty {
                Text("Nessun preferito. Chiudi e scegli Cerca dal + della playlist per trovare un brano.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if data.addableCount == 0 {
                Text("Tutti i preferiti sono già in questa playlist.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(data.rows) { row in
                Button {
                    toggle(row)
                } label: {
                    FavouritePickerLine(
                        row: row,
                        server: server,
                        isPicked: picked.contains(row.id)
                    )
                }
                .buttonStyle(.plain)
                .disabled(row.isInPlaylist)
            }
        } header: {
            Text("Preferiti").textCase(nil)
        } footer: {
            Text("I brani scelti finiscono in fondo alla playlist, nell'ordine in cui li tocchi.")
        }
    }

    /// Picking is by id and keeps its order; a track already in the playlist is not
    /// selectable, so it can never be picked in the first place.
    private func toggle(_ row: FavouritePickerRow) {
        guard !row.isInPlaylist else { return }
        if let index = picked.firstIndex(of: row.id) {
            picked.remove(at: index)
        } else {
            picked.append(row.id)
        }
    }

    /// Adds `ids`, in the order given, resolving the playlist at the moment of the
    /// tap, with the drafts of the rows this sheet drew.
    private func add(_ ids: [String], from data: PlaylistAdditionData) {
        guard let playlist = ModelLookup.playlist(playlistID, in: context) else { return }
        let byID = Dictionary(data.rows.map { ($0.id, $0.track.favouriteDraft) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byID[$0] }
        guard !ordered.isEmpty else { return }
        store.add(ordered, to: playlist)
    }
}

/// One line of the Dai preferiti picker: what the track is, where it is, and
/// whether it has been picked or is already in the playlist.
private struct FavouritePickerLine: View {
    let row: FavouritePickerRow
    let server: ServerState
    let isPicked: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverArt(cover: row.track.cover, side: 40, cornerRadius: 8)
                .opacity(row.isInPlaylist ? 0.5 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.track.title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(Formatting.trackTime(row.track.durationS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            marker
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .opacity(row.isInPlaylist ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private var subtitle: String {
        if row.isInPlaylist {
            return "Già in questa playlist"
        }
        return [row.track.favouriteState.label(server), row.track.artist]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var marker: some View {
        if row.isInPlaylist {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Già nella playlist")
        } else {
            Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isPicked ? Color.accentColor : Color.secondary)
                .accessibilityLabel(isPicked ? "Scelto" : "Non scelto")
        }
    }
}
