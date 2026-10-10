import Foundation
import Observation
import SwiftData

/// Keeps the favourites and playlists on the server as well as on this phone, so a
/// reinstall loses nothing.
///
/// The phone is always the one that answers the interface: every change is saved
/// locally first, by `PlaylistStore`, and this class only ever runs behind it. Nothing
/// on screen waits for it.
///
/// **What "pending" means.** There is no flag. The phone remembers the server's
/// version and a digest of the collection as it was when it last matched the server
/// (`SyncRecord`), and anything that differs from that digest is pending. So a change
/// made offline, one made by a cascade the library sync performed, and one that was
/// never pushed because the app was killed are all found the same way, by looking.
///
/// **First sync** (no remembered version) never resolves anything by discarding a
/// side. It reads the server, works out the result in memory, uploads it, and only
/// then writes it into the phone, so a failure at any point leaves the phone exactly
/// as it was and the whole thing can simply be run again:
/// - server empty, phone empty: nothing to do, the version is remembered;
/// - server empty, phone has data: the phone's collection is uploaded;
/// - server has data, phone empty (a reinstall): the server's collection is taken;
/// - both: a union, the server's version of anything present on both, then uploaded.
///
/// **After that**, a change is pushed with the remembered version, a stale push is
/// answered by taking the server's collection (and saying so), and a launch or return
/// to the foreground pulls. Nothing here repeats on a schedule: a sync is the
/// consequence of a change, a launch, a foreground, or the server coming back.
@Observable
final class CollectionSync {
    enum Status {
        case idle
        case syncing
        case synced(Date)
        case failed(APIError)
    }

    /// How long after the first of a burst of changes the push goes out, so a run of
    /// rapid edits is one request carrying the last of them.
    static let pushDelay: TimeInterval = 2

    private(set) var status: Status = .idle
    /// Whether the phone holds something the server has not been told. Updated
    /// whenever the answer is worked out; the data, not this, is the truth.
    private(set) var hasPendingChanges = false

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let reachability: ServerReachability
    /// Shows a line to the user. `AppModel` points this at `PlaylistStore`, whose
    /// notices already appear on the screens that show favourites and playlists.
    @ObservationIgnored var announce: ((String) -> Void)?

    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(context: ModelContext, settings: AppSettings, reachability: ServerReachability) {
        self.context = context
        self.settings = settings
        self.reachability = reachability
    }

    // MARK: - Events

    /// The launch, a return to the foreground, or the server answering again.
    func syncNow() {
        start()
    }

    /// Favourites or playlists may have changed. Already saved locally by the caller
    /// (or about to be: the push waits `pushDelay`, and reads the store when it runs).
    /// A burst of calls starts one timer.
    func localChanged() {
        guard timer == nil else { return }
        timer = Task {
            do {
                try await Task.sleep(for: .seconds(Self.pushDelay))
            } catch {
                return
            }
            timer = nil
            start()
        }
    }

    /// A different server was saved. The remembered version was about another one, so
    /// the next sync is a first sync again: a merge, which loses nothing either way.
    func addressChanged() {
        timer?.cancel()
        timer = nil
        if let record = try? loadRecord() {
            record.collectionVersion = nil
            record.collectionSyncedDigest = nil
            try? context.save()
        }
        start()
    }

    private func start() {
        if running {
            // Whatever is running may have read the store before this event.
            rerun = true
            return
        }
        running = true
        Task {
            repeat {
                rerun = false
                await run()
            } while rerun
            running = false
        }
    }

    // MARK: - One pass

    private func run() async {
        // Unreachable: the changes stay local and pending, and `ServerReachability`
        // reporting the server back calls `syncNow`. No retry is scheduled here.
        guard reachability.isReachable != false else {
            refreshPending()
            return
        }
        let client: APIClient
        let record: SyncRecord
        do {
            client = try settings.makeClient()
            record = try loadRecord()
        } catch {
            status = .failed(.from(error))
            return
        }

        status = .syncing
        do {
            if record.collectionVersion == nil {
                try await firstSync(client: client, record: record)
            } else if try isPending(record) {
                try await push(client: client, record: record)
            } else {
                try await pull(client: client, record: record)
            }
            status = .synced(Date())
        } catch {
            let problem = APIError.from(error)
            status = problem.isCancellation ? .idle : .failed(problem)
            // The recorded answer said the server was there and this disagreed.
            if problem.kind == .transport {
                reachability.retry()
            }
        }
        refreshPending()
    }

    // MARK: - First sync

    private func firstSync(client: APIClient, record: SyncRecord) async throws {
        // A 409 here means the server moved between reading it and writing it, which
        // with one phone should not happen. The answer is to read it again and merge
        // again, never to take either side whole.
        for _ in 0..<3 {
            let base = try snapshot()
            let server = try await client.collection().value
            let serverContent = CollectionMerge.normalized(server.content)

            if serverContent.isEmpty && base.isEmpty {
                remember(version: server.version, content: base, in: record)
                try context.save()
                return
            }
            if base.isEmpty {
                // A reinstall: the server has it all, the phone has nothing to add.
                try apply(serverContent, base: base)
                remember(version: server.version, content: serverContent, in: record)
                try save("restoring the collection from the server")
                announce?(Self.restoredMessage(serverContent))
                return
            }

            let target = serverContent.isEmpty
                ? base
                : CollectionMerge.merged(local: base, server: serverContent)
            let answer = try await client.putCollection(ServerCollection(version: server.version, content: target))
            switch answer {
            case .accepted(let stored):
                let content = CollectionMerge.normalized(stored.content)
                try apply(content, base: base)
                remember(version: stored.version, content: content, in: record)
                try save("saving the merged collection")
                return
            case .stale:
                continue
            }
        }
        throw APIError(
            kind: .unexpected,
            title: "The first collection sync could not settle",
            url: nil,
            details: ["The server's collection changed under three attempts in a row."],
            message: "Preferiti e playlist non si sono potuti sincronizzare con il server perché cambiavano mentre li leggevo: riproverò al prossimo avvio."
        )
    }

    // MARK: - Pushing and pulling

    private func push(client: APIClient, record: SyncRecord) async throws {
        guard let version = record.collectionVersion else { return }
        let sent = try snapshot()
        let answer = try await client.putCollection(ServerCollection(version: version, content: sent))
        switch answer {
        case .accepted(let stored):
            // `sent` is what was uploaded; if the phone changed again meanwhile, the
            // digest no longer matches the data and the next pass pushes that too.
            record.collectionVersion = stored.version
            record.collectionSyncedDigest = CollectionMerge.digest(sent)
            try save("recording the pushed collection")
        case .stale(let current):
            // The server is ahead of this phone. With one phone that means a
            // reinstall met an old install, or the phone's own state was damaged, so
            // the server's collection is taken whole and the user is told.
            let content = CollectionMerge.normalized(current.content)
            let base = try snapshot()
            try apply(content, base: base)
            remember(version: current.version, content: content, in: record)
            try save("adopting the server's collection")
            announce?("Il server aveva preferiti e playlist più recenti di quelli di questo telefono, quindi ho usato quelli del server. Le modifiche fatte qui e non ancora inviate sono state sostituite.")
        }
    }

    private func pull(client: APIClient, record: SyncRecord) async throws {
        guard let version = record.collectionVersion else { return }
        let base = try snapshot()
        let server = try await client.collection().value
        if server.version > version {
            let content = CollectionMerge.normalized(server.content)
            try apply(content, base: base)
            remember(version: server.version, content: content, in: record)
            try save("applying the server's collection")
        } else if server.version < version {
            // The server has lost state this phone still has (a restored backup, a
            // new database). The phone's copy is the better one: send it.
            try await push(client: client, record: record)
        }
    }

    // MARK: - Pending

    private func isPending(_ record: SyncRecord) throws -> Bool {
        CollectionMerge.digest(try snapshot()) != record.collectionSyncedDigest
    }

    private func refreshPending() {
        guard let record = try? loadRecord(), let content = try? snapshot() else { return }
        if record.collectionVersion == nil {
            hasPendingChanges = !content.isEmpty
        } else {
            hasPendingChanges = CollectionMerge.digest(content) != record.collectionSyncedDigest
        }
    }

    private func remember(version: Int, content: CollectionContent, in record: SyncRecord) {
        record.collectionVersion = version
        record.collectionSyncedDigest = CollectionMerge.digest(content)
    }

    // MARK: - Reading the store

    /// The collection as this phone holds it, in the order the server stores it.
    private func snapshot() throws -> CollectionContent {
        do {
            let favourites = try context.fetch(FetchDescriptor<FavouriteTrack>()).map(Self.content(of:))
            let playlists = try context.fetch(FetchDescriptor<Playlist>()).sorted { left, right in
                if left.sortPosition != right.sortPosition { return left.sortPosition < right.sortPosition }
                if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
                return left.id.uuidString < right.id.uuidString
            }
            let entries = try context.fetch(FetchDescriptor<PlaylistEntry>())
            return CollectionMerge.normalized(CollectionContent(
                favourites: favourites,
                playlists: playlists.map { Self.content(of: $0, entries: entries) }
            ))
        } catch {
            throw APIError.storage("Could not read the favourites and playlists", location: nil, error: error)
        }
    }

    private static func stamp(_ date: Date) -> Double {
        // Milliseconds: a date survives the trip through the server and back to the
        // same number, so equal data is equal in the digest.
        (date.timeIntervalSince1970 * 1000).rounded() / 1000
    }

    private static func content(of favourite: FavouriteTrack) -> CollectionFavourite {
        CollectionFavourite(
            videoID: favourite.videoID,
            title: favourite.title,
            artist: favourite.artist,
            album: favourite.albumName,
            artworkURL: favourite.artworkURL,
            addedAt: stamp(favourite.addedAt)
        )
    }

    private static func content(of playlist: Playlist, entries all: [PlaylistEntry]) -> CollectionPlaylist {
        CollectionPlaylist(
            id: playlist.id.uuidString,
            name: playlist.name,
            createdAt: stamp(playlist.createdAt),
            updatedAt: stamp(playlist.updatedAt),
            entries: PlaylistStore.ordered(all, of: playlist).compactMap(\.trackID)
        )
    }

    // MARK: - Writing the store

    /// Makes the phone hold `target`, except for whatever changed here since `base`.
    ///
    /// `base` is the phone's collection at the moment `target` was worked out. An
    /// item that still equals its `base` form has not been touched since, so the
    /// server's word on it stands; one that differs was edited while a request was in
    /// flight, and it is kept and left pending for the next push. An item the user
    /// removed in that window is not put back, and one they added is not removed.
    /// Called with the phone's current collection as `base`, it is a plain replace.
    ///
    /// Does not save: the caller records the version in the same save, so the data
    /// and the version it belongs to land together or not at all.
    private func apply(_ target: CollectionContent, base: CollectionContent) throws {
        let tracks: [StoredTrack]
        let localFavourites: [FavouriteTrack]
        let localPlaylists: [Playlist]
        let entries: [PlaylistEntry]
        do {
            tracks = try context.fetch(FetchDescriptor<StoredTrack>())
            localFavourites = try context.fetch(FetchDescriptor<FavouriteTrack>())
            localPlaylists = try context.fetch(FetchDescriptor<Playlist>())
            entries = try context.fetch(FetchDescriptor<PlaylistEntry>())
        } catch {
            throw APIError.storage("Could not read the favourites and playlists", location: nil, error: error)
        }
        let trackByID = Dictionary(tracks.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })

        // Favourites. `StoredTrack.favouritedAt` mirrors them, as `PlaylistStore` keeps it.
        let baseFavourites = Dictionary(base.favourites.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        let localFavouriteByID = Dictionary(localFavourites.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        var wantedFavourites = Set<String>()
        for wanted in target.favourites {
            wantedFavourites.insert(wanted.videoID)
            let addedAt = Date(timeIntervalSince1970: wanted.addedAt)
            if let existing = localFavouriteByID[wanted.videoID] {
                guard Self.content(of: existing) == baseFavourites[wanted.videoID] else { continue }
                existing.title = wanted.title
                existing.artist = wanted.artist
                existing.albumName = wanted.album
                existing.artworkURL = wanted.artworkURL
                existing.addedAt = addedAt
            } else if baseFavourites[wanted.videoID] == nil {
                context.insert(FavouriteTrack(
                    videoID: wanted.videoID,
                    title: wanted.title,
                    artist: wanted.artist,
                    albumName: wanted.album,
                    artworkURL: wanted.artworkURL,
                    durationS: trackByID[wanted.videoID]?.durationS,
                    addedAt: addedAt
                ))
            } else {
                continue
            }
            if let track = trackByID[wanted.videoID] {
                track.favouritedAt = addedAt
            }
        }
        for existing in localFavourites where !wantedFavourites.contains(existing.videoID) {
            guard Self.content(of: existing) == baseFavourites[existing.videoID] else { continue }
            if let track = trackByID[existing.videoID] {
                track.favouritedAt = nil
            }
            context.delete(existing)
        }

        // Playlists.
        let basePlaylists = Dictionary(base.playlists.map { (CollectionMerge.key($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        let localPlaylistByKey = Dictionary(localPlaylists.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        var survivors = localPlaylists
        var targetPosition: [ObjectIdentifier: Int] = [:]
        var wantedPlaylists = Set<String>()
        for (index, wanted) in target.playlists.enumerated() {
            // Every id this app writes is a UUID; anything else is not ours to hold.
            guard let uuid = UUID(uuidString: wanted.id) else { continue }
            let key = uuid.uuidString
            wantedPlaylists.insert(key)
            let playlist: Playlist
            if let existing = localPlaylistByKey[key] {
                targetPosition[ObjectIdentifier(existing)] = index
                guard Self.content(of: existing, entries: entries) == basePlaylists[key] else { continue }
                playlist = existing
            } else if basePlaylists[key] == nil {
                playlist = Playlist(name: wanted.name, sortPosition: index)
                playlist.id = uuid
                context.insert(playlist)
                survivors.append(playlist)
                targetPosition[ObjectIdentifier(playlist)] = index
            } else {
                continue
            }
            playlist.name = wanted.name
            playlist.createdAt = Date(timeIntervalSince1970: wanted.createdAt)
            playlist.updatedAt = Date(timeIntervalSince1970: wanted.updatedAt)

            let current = PlaylistStore.ordered(entries, of: playlist)
            guard current.compactMap(\.trackID) != wanted.entries else { continue }
            for entry in current {
                context.delete(entry)
            }
            for (position, videoID) in wanted.entries.enumerated() {
                if let track = trackByID[videoID] {
                    context.insert(PlaylistEntry(position: position, playlist: playlist, track: track))
                } else {
                    context.insert(PlaylistEntry(position: position, playlist: playlist, videoID: videoID))
                }
            }
        }
        for existing in localPlaylists where !wantedPlaylists.contains(existing.id.uuidString) {
            guard Self.content(of: existing, entries: entries) == basePlaylists[existing.id.uuidString] else { continue }
            survivors.removeAll { $0 === existing }
            context.delete(existing)
        }

        // The server's order first, then whatever is only here, in the order it had.
        let ordered = survivors.sorted { left, right in
            let leftPosition = targetPosition[ObjectIdentifier(left)] ?? Int.max
            let rightPosition = targetPosition[ObjectIdentifier(right)] ?? Int.max
            if leftPosition != rightPosition { return leftPosition < rightPosition }
            return left.sortPosition < right.sortPosition
        }
        for (position, playlist) in ordered.enumerated() where playlist.sortPosition != position {
            playlist.sortPosition = position
        }
    }

    private func save(_ activity: String) throws {
        do {
            try context.save()
        } catch {
            // Nothing half-applied survives, and the version was not recorded, so the
            // next pass starts from the same place.
            context.rollback()
            throw APIError.storage("Saving failed while \(activity)", location: nil, error: error)
        }
    }

    private func loadRecord() throws -> SyncRecord {
        let records: [SyncRecord]
        do {
            records = try context.fetch(FetchDescriptor<SyncRecord>())
        } catch {
            throw APIError.storage("Could not read the sync record", location: nil, error: error)
        }
        if let record = records.first {
            return record
        }
        let record = SyncRecord()
        context.insert(record)
        return record
    }

    private static func restoredMessage(_ content: CollectionContent) -> String {
        let favourites = content.favourites.count
        let playlists = content.playlists.count
        let favouriteText = favourites == 1 ? "1 preferito" : "\(favourites) preferiti"
        let playlistText = playlists == 1 ? "1 playlist" : "\(playlists) playlist"
        return "Ho ripristinato dal server \(favouriteText) e \(playlistText)."
    }
}
