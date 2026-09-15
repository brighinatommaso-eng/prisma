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

    /// A playlist's entries in the user's order.
    static func orderedEntries(of playlist: Playlist) -> [PlaylistEntry] {
        playlist.entries
            .filter { !$0.isDeleted }
            .sorted { $0.position < $1.position }
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
        let next = (Self.orderedEntries(of: playlist).map(\.position).max() ?? -1) + 1
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
        renumber(Self.orderedEntries(of: playlist).filter { entry in !entries.contains { $0 === entry } })
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
        for entry in Self.orderedEntries(of: playlist) {
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
        let entries = Self.orderedEntries(of: playlist)
        guard entries.indices.contains(index), entries[index].track != nil else {
            lastError = .invalidInput("Impossibile riprodurre questo brano", detail: "Non è più in libreria: toglilo dalla playlist.")
            return
        }
        let tracks = entries.compactMap(\.track)
        let offset = entries[..<index].filter { $0.track != nil }.count
        playback.play(playlistTracks: tracks, startingAt: offset)
    }

    // MARK: - Favourites

    func toggleFavourite(_ track: StoredTrack) {
        track.favouritedAt = track.isFavourite ? nil : Date()
        save(track.isFavourite ? "adding a favourite" : "removing a favourite")
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
