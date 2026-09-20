import Foundation
import SwiftData
import SwiftUI

/// Where the Aggiungi brani sheet takes tracks from.
enum AddTrackSource: String, CaseIterable, Identifiable {
    /// The collection, several at a time.
    case favourites
    /// YouTube Music, one result at a time.
    case search

    var id: String { rawValue }

    var label: String {
        switch self {
        case .favourites: return "Dai preferiti"
        case .search: return "Cerca"
        }
    }
}

/// Filling a playlist from the playlist, the other way round from
/// `AddToPlaylistSheet`.
///
/// Two sources, one question each. **Dai preferiti** picks several out of the
/// collection at once. **Cerca** is the same YouTube Music search as the Cerca tab,
/// and choosing a result adds it to the playlist *and* to Preferiti, in the
/// not-acquired state — the favourite exists, nothing is downloaded, and no
/// destination is asked for. Downloading is a separate decision, made later in
/// Preferiti.
///
/// Both sources go through `PlaylistStore.add(_:to:)` with `FavouriteDraft`s,
/// because that is the one shape they share: a favourite already in the collection
/// has one, and so does a search result that is in no library at all.
///
/// The sheet is opened by id and resolves the playlist itself, so the screen behind
/// it can change — or the playlist be deleted — while it is up. It reads the store
/// in exactly one place, at the top of its body, for both of its sources, and
/// everything below that is values.
///
/// It follows the plain system styling of the sheets it sits beside
/// (`AddToPlaylistSheet`, `DestinationSheet`) rather than the themed list of a tab.
struct AddTracksToPlaylistSheet: View {
    /// By id: this sheet outlives the row that opened it.
    let playlistID: UUID

    @Environment(PlaylistStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Playlist.sortPosition) private var playlists: [Playlist]
    @Query private var entries: [PlaylistEntry]
    @Query private var favourites: [FavouriteTrack]
    @Query private var tracks: [StoredTrack]

    @State private var source: AddTrackSource = .favourites
    /// The video ids picked in Dai preferiti, **in the order they were picked**:
    /// that is the order they are added in, and the reason this is an array.
    @State private var picked: [String] = []
    @State private var model = SearchModel()

    var body: some View {
        // The one place this sheet reads the store, for both of its sources.
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
                    Section {
                        Picker("Da dove", selection: $source) {
                            ForEach(AddTrackSource.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if let error = store.lastError {
                        Section {
                            ProblemBlock(error: error)
                            Button("Chiudi") { store.clearError() }
                        }
                    }
                    if let notice = store.notice {
                        Section {
                            Text(notice)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Chiudi") { store.clearNotice() }
                        }
                    }

                    switch source {
                    case .favourites:
                        favouritesContent(data)
                    case .search:
                        searchContent(data)
                    }
                }
            }
            .navigationTitle(data.playlistName.map { "Aggiungi a “\($0)”" } ?? "Aggiungi brani")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmation(data)
                }
            }
        }
    }

    /// Dai preferiti confirms a selection; Cerca has already added what was tapped,
    /// so it only needs a way out.
    @ViewBuilder
    private func confirmation(_ data: PlaylistAdditionData) -> some View {
        switch source {
        case .favourites:
            Button(picked.isEmpty ? "Aggiungi" : "Aggiungi (\(picked.count))") {
                add(picked, from: data)
                dismiss()
            }
            .disabled(picked.isEmpty || data.playlistName == nil)
        case .search:
            Button("Fine") { dismiss() }
        }
    }

    // MARK: - Dai preferiti

    @ViewBuilder
    private func favouritesContent(_ data: PlaylistAdditionData) -> some View {
        let server = ServerState(reachability.isReachable)

        Section {
            if data.rows.isEmpty {
                Text("Nessun preferito. Passa a Cerca per trovare un brano: finisce nella playlist e nei preferiti, senza scaricare niente.")
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

    // MARK: - Cerca

    @ViewBuilder
    private func searchContent(_ data: PlaylistAdditionData) -> some View {
        Section {
            TextField("Brano, artista o album", text: $model.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { model.search(settings: settings) }
            Button("Cerca") { model.search(settings: settings) }
                .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Cerca su YouTube Music").textCase(nil)
        } footer: {
            Text("Il brano scelto entra nella playlist e nei preferiti senza scaricare niente. Per averlo sul telefono aprilo nei Preferiti e scegli dove scaricarlo.")
        }

        Section {
            switch model.state {
            case .idle:
                Text("Scrivi che cosa cercare, poi tocca Cerca.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Ricerca in corso…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .failed(let error):
                ProblemBlock("La ricerca non è riuscita. " + PlainLanguage.message(for: error))
            case .loaded(let results):
                let songs = results.response.value
                if songs.isEmpty {
                    Text("Nessun risultato per “\(results.query)”.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    // Indexed rather than keyed by video id: nothing guarantees the
                    // results contain no duplicates.
                    ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                        let draft = Self.draft(of: song)
                        Button {
                            add([draft.videoID], from: data, drafts: [draft.videoID: draft])
                        } label: {
                            SearchPickerLine(
                                draft: draft,
                                isInPlaylist: data.alreadyIn.contains(draft.videoID),
                                isFavourite: data.favouriteIDs.contains(draft.videoID)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(data.alreadyIn.contains(draft.videoID))
                    }
                }
            }
        }
    }

    /// Exactly the draft the plus in Cerca builds: the same fields, so a favourite
    /// created here is indistinguishable from one created there.
    private static func draft(of song: SongResult) -> FavouriteDraft {
        FavouriteDraft(
            videoID: song.videoID,
            title: song.title,
            artist: song.artist,
            albumName: song.album,
            artworkURL: song.artworkURLSmall ?? song.artworkURL,
            durationS: song.durationS
        )
    }

    // MARK: - Adding

    /// Adds `ids`, in the order given, resolving the playlist at the moment of the
    /// tap. `drafts` is for Cerca, whose results are not in the projection; Dai
    /// preferiti takes its drafts from the rows it drew.
    private func add(_ ids: [String], from data: PlaylistAdditionData, drafts: [String: FavouriteDraft] = [:]) {
        guard let playlist = ModelLookup.playlist(playlistID, in: context) else { return }
        let byID = Dictionary(data.rows.map { ($0.id, $0.track.favouriteDraft) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { drafts[$0] ?? byID[$0] }
        guard !ordered.isEmpty else { return }
        store.add(ordered, to: playlist)
        picked.removeAll { id in ordered.contains { $0.videoID == id } }
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

/// One search result inside the sheet.
///
/// No thumbnail on purpose. `RemoteImage` writes its failure from its own `.task`,
/// whenever the network answers and with nothing else changing, and a row that
/// re-renders for that reason must hold nothing from the store — which is the whole
/// point of `SearchThumbnail` owning its own failure in the Cerca tab. A picker does
/// not need the picture, so this holds only values and never re-renders because the
/// network spoke.
private struct SearchPickerLine: View {
    let draft: FavouriteDraft
    let isInPlaylist: Bool
    let isFavourite: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title ?? "Senza titolo")
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Text(Formatting.trackTime(draft.durationS))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: isInPlaylist ? "checkmark.circle" : "plus.circle")
                .foregroundStyle(isInPlaylist ? Color.secondary : Color.accentColor)
                .accessibilityLabel(isInPlaylist ? "Già nella playlist" : "Aggiungi alla playlist e ai preferiti")
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .opacity(isInPlaylist ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let who = [draft.artist, draft.albumName].compactMap { $0 }.joined(separator: " · ")
        if isInPlaylist {
            return ["Già in questa playlist", who].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if isFavourite {
            return ["Già nei preferiti", who].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return who
    }
}
