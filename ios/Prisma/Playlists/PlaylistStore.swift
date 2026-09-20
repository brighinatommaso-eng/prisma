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
        let listed = Self.ordered(all, of: playlist)
        adoptLibraryRows(listed)
        return listed
    }

    /// Gives a slot that only carries a video id its library row, the first time the
    /// library has one.
    ///
    /// A slot added from Cerca names a track that exists nowhere yet. Once it has
    /// been acquired the sync writes a `StoredTrack` with that same id, and from that
    /// moment the slot should be an ordinary slot: it plays, it downloads, and it
    /// goes when the server drops the track, because the cascade on
    /// `StoredTrack.playlistEntries` finally has something to cascade. Doing it here
    /// means every action goes through it — play, download, add, remove, reorder —
    /// and nothing else has to know that two kinds of slot ever existed.
    ///
    /// The projection shows an un-adopted slot correctly in the meantime, by looking
    /// the id up itself, so there is never a moment where the screen is wrong.
    private func adoptLibraryRows(_ entries: [PlaylistEntry]) {
        let wanted = entries.compactMap { $0.track == nil ? $0.videoID : nil }
        guard !wanted.isEmpty else { return }
        let found = ModelLookup.tracks(wanted, in: context)
        guard !found.isEmpty else { return }
        let byID = Dictionary(found.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        var linked = 0
        for entry in entries where entry.track == nil {
            guard let videoID = entry.videoID, let track = byID[videoID] else { continue }
            entry.track = track
            linked += 1
        }
        guard linked > 0 else { return }
        save("linking \(linked) playlist entries to tracks that have arrived in the library")
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

    /// Adds tracks to the end of a playlist, in the order given, and makes sure each
    /// one is in Preferiti.
    ///
    /// Takes drafts rather than tracks because that is the only shape both sources
    /// of the Aggiungi brani sheet share: a favourite already in the collection has
    /// one, and so does a Cerca result that is in no library at all. For the second
    /// kind `addFavourite` creates the favourite — the not-acquired state, with what
    /// search knew and nothing downloaded — and the slot carries the video id until
    /// the track is acquired.
    ///
    /// The end is worked out here, from the store, at the moment of the tap: the
    /// highest position there is now, plus one per track. So a sync that removed a
    /// slot between the sheet being drawn and the button being pressed only lowers
    /// that number, and the new tracks still land after everything that survived.
    /// Within one call the order is the order given, which is the order they were
    /// picked in.
    ///
    /// A track the playlist already holds is skipped rather than added twice: this
    /// is a picker, and it said which tracks were already there. The other direction,
    /// Aggiungi a playlist… on a track row, still allows a second copy on purpose.
    func add(_ drafts: [FavouriteDraft], to playlist: Playlist) {
        guard !drafts.isEmpty else { return }
        let listed = entries(of: playlist)
        var held = Set(listed.compactMap(\.trackID))
        var next = (listed.map(\.position).max() ?? -1) + 1
        var added: [String] = []
        var skipped = 0
        for draft in drafts {
            guard held.insert(draft.videoID).inserted else {
                skipped += 1
                continue
            }
            addFavourite(draft)
            if let track = ModelLookup.track(draft.videoID, in: context) {
                context.insert(PlaylistEntry(position: next, playlist: playlist, track: track))
            } else {
                context.insert(PlaylistEntry(position: next, playlist: playlist, videoID: draft.videoID))
            }
            next += 1
            added.append(draft.title ?? draft.videoID)
        }
        let alreadyThere = skipped == 1
            ? " 1 era già nella playlist."
            : " \(skipped) erano già nella playlist."
        guard !added.isEmpty else {
            notice = "Nessun brano aggiunto a “\(playlist.name)”:" + alreadyThere
            return
        }
        playlist.updatedAt = Date()
        guard save("adding \(added.count) tracks to “\(playlist.name)”") else { return }
        let what = added.count == 1
            ? "“\(added[0])” aggiunto a “\(playlist.name)”."
            : "\(added.count) brani aggiunti a “\(playlist.name)”."
        notice = what + (skipped == 0 ? "" : alreadyThere)
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

    /// Entries that name nothing at all. Deleting a track cascades to its entries,
    /// so this should find nothing; it runs at launch as a safety net and reports
    /// what it removes.
    ///
    /// A slot with no `track` is not an orphan by itself any more: one added from
    /// Cerca has only a video id until its track is acquired, and it is a real line
    /// of the playlist the whole time. An orphan is a slot that belongs to no
    /// playlist, or one that names neither a library row nor an id.
    func removeOrphanedEntries() {
        let orphans: [PlaylistEntry]
        do {
            orphans = try context.fetch(FetchDescriptor<PlaylistEntry>())
                .filter { ($0.track == nil && $0.videoID == nil) || $0.playlist == nil }
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

    /// Starts a device download for every track in the playlist that the server has
    /// and this phone has not.
    ///
    /// A device download fetches GET /tracks/{id}/file, so it needs a track the
    /// server still holds. A slot added from Cerca, and one whose only copy this
    /// phone claimed and then deleted, have no file there to fetch: they have to be
    /// asked of the server again, with a destination, which happens in Preferiti.
    /// They are counted and named here rather than skipped in silence.
    func downloadMissing(in playlist: Playlist) {
        var seen = Set<String>()
        var started = 0
        var busy = 0
        var notAcquired = 0
        for entry in entries(of: playlist) {
            guard let track = entry.track else {
                if let videoID = entry.videoID, seen.insert(videoID).inserted {
                    notAcquired += 1
                }
                continue
            }
            guard seen.insert(track.serverID).inserted else { continue }
            guard track.serverDroppedAt == nil else {
                if track.downloadState != .downloaded {
                    notAcquired += 1
                }
                continue
            }
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
        let stillMissing = notAcquired == 0 ? "" :
            (notAcquired == 1
                ? " 1 brano non è né sul telefono né sul server: aprilo nei Preferiti e scegli dove scaricarlo."
                : " \(notAcquired) brani non sono né sul telefono né sul server: aprili nei Preferiti e scegli dove scaricarli.")
        if started == 0 && busy == 0 {
            notice = (notAcquired == 0
                      ? "Tutti i brani di “\(playlist.name)” sono già scaricati."
                      : "Non c'è niente da scaricare dal server per “\(playlist.name)”.") + stillMissing
        } else {
            notice = (started == 1 ? "Avviato 1 download" : "Avviati \(started) download")
                + (busy > 0 ? ", \(busy) erano già in corso" : "")
                + ". La riga di ogni brano mostra l'avanzamento o perché non è partito."
                + stillMissing
        }
    }

    /// Plays the playlist from the entry at `index` in its displayed order.
    func play(_ playlist: Playlist, fromEntryAt index: Int) {
        let listed = entries(of: playlist)
        guard listed.indices.contains(index) else {
            lastError = .invalidInput("Impossibile riprodurre questo brano", detail: "Non è più in questa playlist: riapri la schermata e riprova.")
            return
        }
        // Told apart, because they need different things of the user: a slot whose
        // library row has gone can only be removed, while one added da Cerca has
        // simply never been downloaded anywhere yet.
        guard listed[index].track != nil else {
            lastError = listed[index].videoID == nil
                ? .invalidInput("Impossibile riprodurre questo brano", detail: "Non è più in libreria: toglilo dalla playlist.")
                : .invalidInput("Impossibile riprodurre questo brano", detail: "Non è ancora stato scaricato né sul telefono né sul server: aprilo nei Preferiti e scegli dove scaricarlo.")
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
        // Preferiti is newest first, and every one of these becomes a favourite in
        // the same instant, so the order is given rather than left to whatever the
        // fetch happened to return: artist, then album, then the album's own
        // numbering. One second apart, so the list reads that way and reads the same
        // way after every launch.
        let ordered = tracks.sorted { left, right in
            let byArtist = (left.album?.artist ?? "").localizedStandardCompare(right.album?.artist ?? "")
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            let byAlbum = (left.album?.title ?? "").localizedStandardCompare(right.album?.title ?? "")
            if byAlbum != .orderedSame { return byAlbum == .orderedAscending }
            if left.trackNo != right.trackNo { return (left.trackNo ?? .max) < (right.trackNo ?? .max) }
            return (left.title ?? "").localizedStandardCompare(right.title ?? "") == .orderedAscending
        }
        for (offset, track) in ordered.enumerated() where !already.contains(track.serverID) {
            context.insert(FavouriteTrack(
                videoID: track.serverID,
                title: track.title,
                artist: track.album?.artist,
                albumName: track.album?.title,
                artworkURL: nil,
                durationS: track.durationS,
                addedAt: now.addingTimeInterval(-Double(offset))
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
