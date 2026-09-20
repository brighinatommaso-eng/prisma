import Foundation
import Observation
import SwiftData
import SwiftUI

/// Every change to playlists and favourites. Stored only on this iPhone: no
/// backend, no sync.
@Observable
final class PlaylistStore {
    /// The last failed action, shown until dismissed.
    private(set) var lastError: APIError?
    /// What the last bulk action did, e.g. how many downloads it started.
    private(set) var notice: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let playback: PlaybackEngine

    init(context: ModelContext, downloads: DownloadManager, playback: PlaybackEngine) {
        self.context = context
        self.downloads = downloads
        self.playback = playback
    }

    // MARK: - Ordering

    /// The entries of `playlist`, in the user's order, picked out of `all`.
    ///
    /// `all` is a `@Query` result or a fetch, never `playlist.entries`: a to-many
    /// relationship is a cache on the playlist object, and after the sync deletes a
    /// track it can still list the entry that went with it. Membership is decided by
    /// comparing references, which reads nothing from either object.
    static func ordered(_ all: [PlaylistEntry], of playlist: Playlist) -> [PlaylistEntry] {
        let wanted = ObjectIdentifier(playlist)
        return all
            .filter { entry in entry.playlist.map { ObjectIdentifier($0) == wanted } ?? false }
            .sorted { $0.position < $1.position }
    }

    /// The same, read from the store now. For actions, which run long after the body
    /// that drew their button.
    func entries(of playlist: Playlist) -> [PlaylistEntry] {
        let all: [PlaylistEntry]
        do {
            all = try context.fetch(FetchDescriptor<PlaylistEntry>())
        } catch {
            lastError = .storage("Could not read the playlist's tracks", location: nil, error: error,
                                 message: "Impossibile leggere i brani della playlist sul telefono: riavvia l'app; se si ripete, controlla lo spazio libero.")
            return []
        }
        return Self.ordered(all, of: playlist)
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named rawName: String) -> Playlist? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            lastError = .invalidInput("La playlist ha bisogno di un nome", detail: "Scrivi un nome, poi crea la playlist.")
            return nil
        }
        let next: Int
        do {
            next = (try context.fetch(FetchDescriptor<Playlist>()).map(\.sortPosition).max() ?? -1) + 1
        } catch {
            lastError = .storage("Could not read the existing playlists", location: nil, error: error,
                                 message: "Impossibile leggere le playlist sul telefono, quindi quella nuova non è stata creata: riavvia l'app e riprova.")
            return nil
        }
        let playlist = Playlist(name: name, sortPosition: next)
        context.insert(playlist)
        guard save("creating the playlist “\(name)”") else { return nil }
        return playlist
    }

    func rename(_ playlist: Playlist, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            lastError = .invalidInput("La playlist ha bisogno di un nome", detail: "Un nome vuoto non viene salvato: la playlist resta “\(playlist.name)”.")
            return
        }
        playlist.name = name
        playlist.updatedAt = Date()
        save("renaming the playlist to “\(name)”")
    }

    func delete(_ playlists: [Playlist]) {
        let names = playlists.map(\.name)
        for playlist in playlists {
            context.delete(playlist)
        }
        save("deleting \(names.joined(separator: ", "))")
    }

    /// `ordered` is the list as displayed; the new order is stored in `sortPosition`.
    func movePlaylists(_ ordered: [Playlist], from source: IndexSet, to destination: Int) {
        var reordered = ordered
        reordered.move(fromOffsets: source, toOffset: destination)
        for (position, playlist) in reordered.enumerated() where playlist.sortPosition != position {
            playlist.sortPosition = position
        }
        save("reordering playlists")
    }

    // MARK: - Entries

    func add(_ track: StoredTrack, to playlist: Playlist) {
        let next = (entries(of: playlist).map(\.position).max() ?? -1) + 1
        let entry = PlaylistEntry(position: next, playlist: playlist, track: track)
        context.insert(entry)
        playlist.updatedAt = Date()
        if save("adding “\(track.title ?? track.serverID)” to “\(playlist.name)”") {
            notice = "“\(track.title ?? track.serverID)” aggiunto a “\(playlist.name)”."
        }
    }

    func remove(_ entries: [PlaylistEntry], from playlist: Playlist) {
        for entry in entries {
            context.delete(entry)
        }
        renumber(self.entries(of: playlist).filter { entry in !entries.contains { $0 === entry } })
        playlist.updatedAt = Date()
        save("removing tracks from “\(playlist.name)”")
    }

    /// `ordered` is the list as displayed; the new order is stored in `position`.
    func moveEntries(in playlist: Playlist, ordered: [PlaylistEntry], from source: IndexSet, to destination: Int) {
        var reordered = ordered
        reordered.move(fromOffsets: source, toOffset: destination)
        renumber(reordered)
        playlist.updatedAt = Date()
        save("reordering “\(playlist.name)”")
    }

    private func renumber(_ ordered: [PlaylistEntry]) {
        for (position, entry) in ordered.enumerated() where entry.position != position {
            entry.position = position
        }
    }

    /// Entries whose track is gone. Deleting a track cascades to its entries, so this
    /// should find nothing; it runs at launch as a safety net and reports what it
    /// removes.
    func removeOrphanedEntries() {
        let orphans: [PlaylistEntry]
        do {
            orphans = try context.fetch(FetchDescriptor<PlaylistEntry>()).filter { $0.track == nil || $0.playlist == nil }
        } catch {
            lastError = .storage("Could not check playlists for removed tracks", location: nil, error: error,
                                 message: "Impossibile controllare le playlist per i brani rimossi dalla libreria: riavvia l'app; se si ripete, controlla lo spazio libero.")
            return
        }
        guard !orphans.isEmpty else { return }
        let affected = Set(orphans.compactMap { $0.playlist?.name })
        for orphan in orphans {
            context.delete(orphan)
        }
        if save("removing entries for tracks no longer in the library") {
            notice = (orphans.count == 1
                      ? "Rimosso 1 brano che non è più in libreria"
                      : "Rimossi \(orphans.count) brani che non sono più in libreria")
                + (affected.isEmpty ? "." : " dalle playlist \(affected.sorted().joined(separator: ", ")).")
        }
    }

    // MARK: - Downloads and playback

    /// Starts a download for every track in the playlist that is not on the phone.
    func downloadMissing(in playlist: Playlist) {
        var seen = Set<String>()
        var started = 0
        var busy = 0
        for entry in entries(of: playlist) {
            guard let track = entry.track, seen.insert(track.serverID).inserted else { continue }
            switch track.downloadState {
            case .notDownloaded, .failed, .cancelled:
                downloads.download(track)
                started += 1
            case .queued, .downloading:
                busy += 1
            case .downloaded:
                break
            }
        }
        if started == 0 && busy == 0 {
            notice = "Tutti i brani di “\(playlist.name)” sono già scaricati."
        } else {
            notice = (started == 1 ? "Avviato 1 download" : "Avviati \(started) download")
                + (busy > 0 ? ", \(busy) erano già in corso" : "")
                + ". La riga di ogni brano mostra l'avanzamento o perché non è partito."
        }
    }

    /// Plays the playlist from the entry at `index` in its displayed order.
    func play(_ playlist: Playlist, fromEntryAt index: Int) {
        let listed = entries(of: playlist)
        guard listed.indices.contains(index), listed[index].track != nil else {
            lastError = .invalidInput("Impossibile riprodurre questo brano", detail: "Non è più in libreria: toglilo dalla playlist.")
            return
        }
        let tracks = listed.compactMap(\.track)
        let offset = listed[..<index].filter { $0.track != nil }.count
        playback.play(playlistTracks: tracks, startingAt: offset)
    }

    // MARK: - Favourites

    /// Preferiti is a collection of its own: a `FavouriteTrack` keyed by video id,
    /// which exists whether or not the track does. `StoredTrack.favouritedAt` is
    /// kept in step here, and only here, so every row projection keeps reading one
    /// field and an older build still finds its favourites.
    ///
    /// Takes values, not a track: Cerca favourites a result that is in no library.
    func toggleFavourite(_ draft: FavouriteDraft) {
        if let existing = storedFavourite(draft.videoID) {
            context.delete(existing)
            ModelLookup.track(draft.videoID, in: context)?.favouritedAt = nil
            save("removing “\(draft.title ?? draft.videoID)” from the favourites")
        } else {
            addFavourite(draft)
            save("adding “\(draft.title ?? draft.videoID)” to the favourites")
        }
    }

    /// Adds the favourite if it is not already there, without saving. The callers
    /// that also acquire a track save once, after both changes.
    func addFavourite(_ draft: FavouriteDraft) {
        let now = Date()
        if let existing = storedFavourite(draft.videoID) {
            // Already a favourite: fill in anything it did not know yet, e.g. a
            // favourite added from search before the album title was known.
            existing.title = existing.title ?? draft.title
            existing.artist = existing.artist ?? draft.artist
            existing.albumName = existing.albumName ?? draft.albumName
            existing.artworkURL = existing.artworkURL ?? draft.artworkURL
            existing.durationS = existing.durationS ?? draft.durationS
        } else {
            context.insert(FavouriteTrack(
                videoID: draft.videoID,
                title: draft.title,
                artist: draft.artist,
                albumName: draft.albumName,
                artworkURL: draft.artworkURL,
                durationS: draft.durationS,
                addedAt: now
            ))
        }
        ModelLookup.track(draft.videoID, in: context)?.favouritedAt = now
    }

    /// Adds the favourite and saves. For the plus in Cerca, which downloads nothing.
    func addToFavourites(_ draft: FavouriteDraft) {
        guard storedFavourite(draft.videoID) == nil else { return }
        addFavourite(draft)
        if save("adding “\(draft.title ?? draft.videoID)” to the favourites") {
            notice = "“\(draft.title ?? draft.videoID)” aggiunto ai preferiti."
        }
    }

    private func storedFavourite(_ videoID: String) -> FavouriteTrack? {
        ModelLookup.favourite(videoID, in: context)
    }

    /// Makes every track already on this phone a favourite, once.
    ///
    /// Preferiti is the only place a track is browsed now, so without this the
    /// library the user already has would have nowhere to be seen. Purely additive:
    /// it inserts favourites and sets a flag, and deletes and changes nothing, so a
    /// library installed by an earlier build survives it untouched. It runs again at
    /// the next launch if it could not finish, and inserting a favourite that is
    /// already there does nothing.
    func migrateFavourites() {
        let records: [SyncRecord]
        let tracks: [StoredTrack]
        do {
            records = try context.fetch(FetchDescriptor<SyncRecord>())
            guard records.first?.favouritesMigratedAt == nil else { return }
            tracks = try context.fetch(FetchDescriptor<StoredTrack>())
        } catch {
            lastError = .storage("Could not read the library to create the favourites", location: nil, error: error,
                                 message: "I brani già sul telefono non si sono potuti aggiungere ai preferiti perché la libreria non si è letta: riavvia l'app; se si ripete, controlla lo spazio libero.")
            return
        }

        let record: SyncRecord
        if let existing = records.first {
            record = existing
        } else {
            record = SyncRecord()
            context.insert(record)
        }

        let already = Set(existingFavouriteIDs())
        var added = 0
        let now = Date()
        for track in tracks where !already.contains(track.serverID) {
            context.insert(FavouriteTrack(
                videoID: track.serverID,
                title: track.title,
                artist: track.album?.artist,
                albumName: track.album?.title,
                artworkURL: nil,
                durationS: track.durationS,
                addedAt: track.favouritedAt ?? now
            ))
            added += 1
        }
        for track in tracks where track.favouritedAt == nil {
            track.favouritedAt = now
        }
        record.favouritesMigratedAt = now
        guard save("making every track on this phone a favourite") else { return }
        if added > 0 {
            notice = added == 1
                ? "1 brano già sul telefono è stato aggiunto ai preferiti."
                : "\(added) brani già sul telefono sono stati aggiunti ai preferiti."
        }
    }

    private func existingFavouriteIDs() -> [String] {
        do {
            return try context.fetch(FetchDescriptor<FavouriteTrack>()).map(\.videoID)
        } catch {
            return []
        }
    }

    // MARK: - Errors

    func clearError() {
        lastError = nil
    }

    func clearNotice() {
        notice = nil
    }

    @discardableResult
    private func save(_ activity: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            lastError = .storage("Saving failed while \(activity)", location: nil, error: error,
                                 message: "Il salvataggio sul telefono non è riuscito, quindi l'ultima modifica alle playlist o ai preferiti potrebbe non essere registrata: controlla lo spazio libero e riprova.")
            return false
        }
    }
}
