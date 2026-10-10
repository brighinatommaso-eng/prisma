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
/// (`SyncRecord`), and anything that differs from that digest is pending. A change
/// made offline and one never pushed because the app was killed are found the same
/// way, by looking.
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
/// **After that**, a change is pushed with the remembered version, and a launch or
/// return to the foreground pulls. A push the server refuses as stale (409) is a
/// conflict only when what the server holds is not something this phone sent: the
/// digest of every upload is written down before it goes, so an upload that was
/// stored but whose answer never arrived is recognised, its version adopted, and the
/// edits made since are pushed on top of it. Only a collection this phone did not
/// send replaces the phone's, and then the user is told.
///
/// **When it runs.** A sync is the consequence of an event: a change, the interface
/// coming on screen, the server answering again, a different address. A pass that
/// fails for a reason that may pass (the network, a 5xx) is tried again a bounded
/// number of times while there is something to push; one that fails for a reason
/// that will not (a 422, a backend without the endpoint) is shown and left alone
/// until what the phone holds, or the address it talks to, is different.
@Observable
final class CollectionSync {
    /// How long after the first of a burst of changes the push goes out, so a run of
    /// rapid edits is one request carrying the last of them.
    static let pushDelay: TimeInterval = 2
    /// The waits between attempts after a failure that may pass. When they run out
    /// the change stays pending until the next event.
    static let retryDelays: [TimeInterval] = [5, 15, 45, 120, 300]

    /// When a pass last finished without a failure.
    private(set) var lastSyncedAt: Date?
    /// Why the last pass failed, already in Italian. nil once one succeeds.
    private(set) var problem: APIError?
    /// Whether the phone holds something the server has not been told. Updated
    /// whenever the answer is worked out; the data, not this, is the truth.
    private(set) var hasPendingChanges = false
    /// A line about something this class did to the collection: a restore, or the
    /// server's collection taking the phone's place. Shown until dismissed.
    private(set) var notice: String?

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let reachability: ServerReachability

    /// False until the interface has been on screen in this process. iOS also
    /// launches the app in the background, to hand over a finished download, and
    /// nothing is synced then.
    @ObservationIgnored private var active = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    /// An event that wants the server read, not only a pending change pushed.
    @ObservationIgnored private var pullRequested = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var retryTimer: Task<Void, Never>?
    @ObservationIgnored private var retryAttempt = 0
    /// Bumped when the server address changes. A pass that started before it
    /// discards whatever it learned from the old client.
    @ObservationIgnored private var generation = 0
    /// Digest of the phone's collection when a pass failed for good. While the phone
    /// still holds exactly that, the same request is not sent again.
    @ObservationIgnored private var refusedDigest: String?
    /// The server holds something this phone cannot store. Nothing is pushed, and
    /// nothing of the server's is taken, until a read of the server finds it gone.
    @ObservationIgnored private var held = false

    /// The address changed under a pass: nothing it learned may be written.
    private struct Superseded: Error {}
    /// The server's collection has playlists this app cannot represent.
    private struct Held: Error {
        let ids: [String]
    }

    init(context: ModelContext, settings: AppSettings, reachability: ServerReachability) {
        self.context = context
        self.settings = settings
        self.reachability = reachability
        do {
            lastSyncedAt = try context.fetch(FetchDescriptor<SyncRecord>()).first?.collectionLastSyncAt
        } catch {
            problem = Self.inItalian(.storage("Could not read the sync record", location: nil, error: error))
        }
    }

    // MARK: - Events

    /// The interface is on screen: at launch, and on every return to the foreground.
    func appBecameActive() {
        active = true
        start(pull: true)
    }

    /// `ServerReachability` reports the server back. Changes made while it was away
    /// are pushed now.
    func serverBecameReachable() {
        start(pull: true)
    }

    /// Favourites or playlists may have changed. Already saved locally by the caller
    /// (or about to be: the push waits `pushDelay`, and reads the store when it runs).
    /// A burst of calls starts one timer. Nothing is read from the server for this:
    /// a pending change is pushed, and a save that changed nothing costs no request.
    func localChanged() {
        guard timer == nil else { return }
        timer = Task {
            do {
                try await Task.sleep(for: .seconds(Self.pushDelay))
            } catch {
                return
            }
            timer = nil
            start(pull: false)
        }
    }

    /// A different address was saved. It is the same server by another name, so
    /// nothing remembered is thrown away; but a pass in flight was talking to the old
    /// client and must not write what it hears back, and a failure that was final
    /// for the old address may not be for this one.
    func addressChanged() {
        generation += 1
        refusedDigest = nil
        held = false
        start(pull: true)
    }

    func clearNotice() {
        notice = nil
    }

    /// An event: it supersedes any retry that was waiting, and starts the count again.
    private func start(pull: Bool) {
        guard active else { return }
        if pull {
            pullRequested = true
        }
        retryTimer?.cancel()
        retryTimer = nil
        retryAttempt = 0
        begin()
    }

    private func begin() {
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
        let wantsPull = pullRequested
        pullRequested = false
        let pass = generation
        // Unreachable: the changes stay local and pending, and `ServerReachability`
        // reporting the server back is what runs this again.
        guard reachability.isReachable != false else {
            refreshPending()
            return
        }
        do {
            let client = try settings.makeClient()
            let localDigest = CollectionMerge.digest(try snapshot())
            if held {
                // Only an event that reads the server may find out it is clean again.
                guard wantsPull else { return }
                try await inspect(client: client, pass: pass)
                held = false
                pullRequested = true
                rerun = true
                return
            }
            if let refusedDigest, refusedDigest == localDigest {
                // Shown, not retried: the phone would send exactly what failed.
                return
            }
            refusedDigest = nil

            let record = try loadRecord()
            if record.collectionVersion == nil {
                try await firstSync(client: client, pass: pass)
            } else if localDigest != record.collectionSyncedDigest {
                try await push(client: client, pass: pass)
            } else if wantsPull {
                try await pull(client: client, pass: pass)
            } else {
                // A save that changed nothing in the collection.
                return
            }
            try succeeded()
        } catch is Superseded {
            // `addressChanged` already asked for another pass.
        } catch let hold as Held {
            held = true
            problem = Self.heldProblem(hold.ids)
        } catch {
            failed(.from(error))
        }
        refreshPending()
    }

    private func succeeded() throws {
        let now = Date()
        try commit("recording the sync time") { record in
            record.collectionLastSyncAt = now
        }
        lastSyncedAt = now
        problem = nil
        retryAttempt = 0
    }

    private func failed(_ error: APIError) {
        guard !error.isCancellation else { return }
        problem = Self.inItalian(error)
        if Self.mayPass(error) {
            // The recorded answer said the server was there and this disagreed.
            if error.kind == .transport {
                reachability.retry()
            }
            scheduleRetry()
        } else if Self.isFinal(error) {
            do {
                refusedDigest = CollectionMerge.digest(try snapshot())
            } catch {
                // The store could not be read to remember what was refused. The
                // failure is on screen either way; the next event will try again.
                refusedDigest = nil
            }
        }
    }

    /// One more attempt after a wait, while there is something to push. Bounded by
    /// `retryDelays`; an event in the meantime replaces it.
    private func scheduleRetry() {
        refreshPending()
        guard hasPendingChanges, retryTimer == nil, retryAttempt < Self.retryDelays.count else { return }
        let delay = Self.retryDelays[retryAttempt]
        retryAttempt += 1
        retryTimer = Task {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            retryTimer = nil
            begin()
        }
    }

    /// Throws if the server address changed since the pass with this number began.
    private func stillCurrent(_ pass: Int) throws {
        if pass != generation {
            throw Superseded()
        }
    }

    // MARK: - First sync

    private func firstSync(client: APIClient, pass: Int) async throws {
        // A 409 here means the server moved between reading it and writing it, which
        // with one phone should not happen. The answer is to read it again and merge
        // again, never to take either side whole.
        for _ in 0..<3 {
            let base = try snapshot()
            let server = try await client.collection().value
            try stillCurrent(pass)
            let serverContent = CollectionMerge.normalized(server.content)
            try refuseForeign(serverContent)

            if serverContent.isEmpty && base.isEmpty {
                try commit("remembering the server's version") { record in
                    remember(version: server.version, content: base, in: record)
                }
                return
            }
            if base.isEmpty {
                // A reinstall: the server has it all, the phone has nothing to add.
                try commit("restoring the collection from the server") { record in
                    try apply(serverContent, base: base)
                    remember(version: server.version, content: serverContent, in: record)
                }
                notice = Self.restoredMessage(serverContent)
                return
            }

            let target = serverContent.isEmpty
                ? base
                : CollectionMerge.merged(local: base, server: serverContent)
            let answer = try await client.putCollection(ServerCollection(version: server.version, content: target))
            try stillCurrent(pass)
            switch answer {
            case .accepted(let stored):
                let content = CollectionMerge.normalized(stored.content)
                try commit("saving the merged collection") { record in
                    try apply(content, base: base)
                    remember(version: stored.version, content: content, in: record)
                }
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
            message: "Preferiti e playlist non si sono potuti sincronizzare con il server perché cambiavano mentre li leggevo: riproverò alla prossima apertura dell'app."
        )
    }

    // MARK: - Pushing and pulling

    private func push(client: APIClient, pass: Int) async throws {
        let sent = try snapshot()
        let sentDigest = CollectionMerge.digest(sent)
        var known: Int?
        // Written down before the request leaves: if the server stores this and the
        // answer never arrives, the 409 that follows carries exactly this content,
        // and that is how it is told apart from somebody else's.
        try commit("noting what is about to be sent") { record in
            known = record.collectionVersion
            let earlier = (record.collectionSentDigests ?? []).filter { $0 != sentDigest }
            record.collectionSentDigests = Array((earlier + [sentDigest]).suffix(8))
        }
        guard let version = known else { return }

        let answer = try await client.putCollection(ServerCollection(version: version, content: sent))
        try stillCurrent(pass)
        switch answer {
        case .accepted(let stored):
            // If the phone changed again meanwhile, the digest no longer matches the
            // data, and the timer that change started pushes that too.
            try commit("recording the pushed collection") { record in
                record.collectionVersion = stored.version
                record.collectionSyncedDigest = sentDigest
                record.collectionSentDigests = nil
            }
        case .stale(let current):
            let content = CollectionMerge.normalized(current.content)
            let serverDigest = CollectionMerge.digest(content)
            let local = try snapshot()
            let localDigest = CollectionMerge.digest(local)
            let earlier = try loadRecord().collectionSentDigests ?? []
            if earlier.contains(serverDigest) || serverDigest == localDigest {
                // The server holds something this phone sent: an upload whose answer
                // was lost. Its version is adopted and nothing here is touched; what
                // was edited since is still pending, and goes out on top of it.
                try commit("adopting the version of an earlier upload") { record in
                    record.collectionVersion = current.version
                    record.collectionSyncedDigest = serverDigest
                    record.collectionSentDigests = nil
                }
                if serverDigest != localDigest {
                    rerun = true
                }
                return
            }
            // A real conflict: the server holds a collection this phone never sent.
            // With one phone that is a reinstall meeting an old install, or damaged
            // state here, so the server's is taken whole and the user is told.
            try refuseForeign(content)
            try commit("adopting the server's collection") { record in
                try apply(content, base: local)
                remember(version: current.version, content: content, in: record)
                record.collectionSentDigests = nil
            }
            notice = "Sul server c'erano preferiti e playlist diversi da quelli di questo telefono, e più recenti, quindi ho usato quelli del server. Le modifiche fatte qui e non ancora inviate sono state sostituite."
        }
    }

    private func pull(client: APIClient, pass: Int) async throws {
        let base = try snapshot()
        let server = try await client.collection().value
        try stillCurrent(pass)
        let content = CollectionMerge.normalized(server.content)
        let serverDigest = CollectionMerge.digest(content)
        let record = try loadRecord()
        guard let version = record.collectionVersion else { return }

        if server.version > version {
            if (record.collectionSentDigests ?? []).contains(serverDigest) {
                // An upload of this phone's whose answer was lost: the version is
                // adopted, and whatever differs here now is pushed next.
                try commit("adopting the version of an earlier upload") { record in
                    record.collectionVersion = server.version
                    record.collectionSyncedDigest = serverDigest
                    record.collectionSentDigests = nil
                }
                rerun = true
                return
            }
            try refuseForeign(content)
            try commit("applying the server's collection") { record in
                try apply(content, base: base)
                remember(version: server.version, content: content, in: record)
                record.collectionSentDigests = nil
            }
        } else if server.version < version {
            // The server has lost state this phone still has (a restored backup, a
            // new database). The phone's copy is the better one: send it.
            try refuseForeign(content)
            try await push(client: client, pass: pass)
        }
    }

    /// Reads the server only to learn whether it still holds something this phone
    /// cannot store. Changes nothing anywhere.
    private func inspect(client: APIClient, pass: Int) async throws {
        let server = try await client.collection().value
        try stillCurrent(pass)
        try refuseForeign(CollectionMerge.normalized(server.content))
    }

    /// Throws when the collection has a playlist this app could not hold: an id that
    /// is not a UUID, or two ids that are the same UUID written differently. Taking
    /// such a collection would drop that playlist here, and the next push would then
    /// drop it from the server too.
    private func refuseForeign(_ content: CollectionContent) throws {
        var seen = Set<String>()
        var foreign: [String] = []
        for playlist in content.playlists {
            if let uuid = UUID(uuidString: playlist.id), seen.insert(uuid.uuidString).inserted {
                continue
            }
            foreign.append(playlist.id)
        }
        if !foreign.isEmpty {
            throw Held(ids: foreign)
        }
    }

    // MARK: - Failures, in Italian

    /// A failure that may not repeat: the network, or the server having a bad moment.
    private static func mayPass(_ error: APIError) -> Bool {
        if error.kind == .transport { return true }
        guard error.kind == .http, let status = error.httpStatus else { return false }
        return status >= 500 || status == 408 || status == 425 || status == 429
    }

    /// A failure that sending the same thing again cannot fix.
    private static func isFinal(_ error: APIError) -> Bool {
        switch error.kind {
        case .http:
            return !mayPass(error)
        case .decoding, .invalidResponse:
            return true
        case .notConfigured, .invalidAddress, .invalidInput, .cancelled, .transport,
             .notAnImage, .storage, .verification, .unexpected:
            return false
        }
    }

    /// The same failure with a sentence that says what it means for the collection.
    /// Anything not named here already reads in Italian through `PlainLanguage`.
    private static func inItalian(_ error: APIError) -> APIError {
        guard error.message == nil else { return error }
        var copy = error
        if error.kind == .http, error.httpStatus == 422 {
            copy.message = "Il server ha rifiutato i preferiti e le playlist di questo telefono perché non li considera validi, quindi sul server non sono stati salvati: sul telefono ci sono ancora tutti. Non riprovo finché non cambiano."
        } else if error.kind == .http, error.httpStatus == 404 || error.httpStatus == 405 {
            copy.message = "Il server non sa ancora salvare preferiti e playlist: aggiorna il backend. Fino ad allora restano solo su questo telefono."
        } else if error.kind == .decoding || error.kind == .invalidResponse {
            copy.message = "La risposta del server su preferiti e playlist non è leggibile: app e backend potrebbero non essere allineati, quindi aggiorna il backend. Sul telefono non è cambiato nulla."
        } else if error.kind == .storage {
            copy.message = "Non è stato possibile leggere o salvare preferiti e playlist sul telefono durante la sincronizzazione: controlla lo spazio libero. Riproverò alla prossima apertura dell'app."
        }
        return copy
    }

    private static func heldProblem(_ ids: [String]) -> APIError {
        let count = ids.count == 1 ? "una playlist" : "\(ids.count) playlist"
        return APIError(
            kind: .invalidResponse,
            title: "The server's collection holds playlists this app cannot store",
            url: nil,
            details: ["Playlist ids: " + ids.joined(separator: ", ")],
            message: "Sul server c'è \(count) che questa app non sa leggere, quindi la sincronizzazione di preferiti e playlist è ferma: non tocco né il telefono né il server finché non viene sistemata sul server."
        )
    }

    // MARK: - Pending

    private func refreshPending() {
        do {
            let record = try context.fetch(FetchDescriptor<SyncRecord>()).first
            let content = try snapshot()
            if record?.collectionVersion != nil {
                hasPendingChanges = CollectionMerge.digest(content) != record?.collectionSyncedDigest
            } else {
                hasPendingChanges = !content.isEmpty
            }
        } catch {
            // Not being able to tell is itself the failure to show.
            problem = Self.inItalian(.from(error))
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
            let favourites = try context.fetch(FetchDescriptor<FavouriteTrack>()).map { Self.content(of: $0) }
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
    /// Does not save: `commit` does, with the version, so the data and the version
    /// it belongs to land together or not at all.
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

    /// One write to the store, all of it or none.
    ///
    /// Whatever else is unsaved in this context is saved first. So if the write
    /// fails, rolling back undoes this write and nothing that belonged to anyone
    /// else: the context was clean when it began.
    private func commit(_ activity: String, _ body: (SyncRecord) throws -> Void) throws {
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                throw APIError.storage("Saving failed before \(activity)", location: nil, error: error)
            }
        }
        do {
            let record = try loadRecord()
            try body(record)
            try context.save()
        } catch {
            context.rollback()
            if let known = error as? APIError {
                throw known
            }
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
