import Foundation
import Observation
import SwiftData
import UIKit

/// Brings the local SwiftData mirror in line with the server's /library.
///
/// The local store is the source of truth for every screen; this is the only code
/// that changes the catalogue. A failed sync leaves the store exactly as it was.
@Observable
final class LibrarySync {
    enum Status {
        case idle
        case syncing(started: Date, since: Int?)
        case succeeded(Date)
        case failed(APIError)
    }

    /// Seconds subtracted from the stored `server_time` before sending it as `since`.
    ///
    /// The backend compares whole-second `updated_at > since`, and computes
    /// `server_time` after its query. A row written in that same second would be
    /// missed by every later delta. Asking for a few seconds of overlap costs
    /// nothing, because applying an album or a deletion twice is harmless.
    static let overlapSeconds = 5

    private(set) var status: Status = .idle

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private var current: Task<Void, Never>?

    init(context: ModelContext, settings: AppSettings, downloads: DownloadManager) {
        self.context = context
        self.settings = settings
        self.downloads = downloads
    }

    var isSyncing: Bool {
        if case .syncing = status { return true }
        return false
    }

    /// For buttons.
    func syncNow(full: Bool) {
        _ = start(full: full)
    }

    /// For pull-to-refresh: returns when the sync has finished. The work runs in
    /// its own task, so SwiftUI ending the refresh gesture cannot cancel it.
    func refresh() async {
        await start(full: false).value
    }

    private func start(full: Bool) -> Task<Void, Never> {
        if let current {
            return current
        }
        let task = Task {
            await run(full: full)
            current = nil
        }
        current = task
        return task
    }

    private func run(full: Bool) async {
        let client: APIClient
        let record: SyncRecord
        do {
            client = try settings.makeClient()
            record = try loadRecord()
        } catch {
            status = .failed(.from(error))
            return
        }

        let since = full ? nil : record.lastServerTime.map { max(0, $0 - Self.overlapSeconds) }
        status = .syncing(started: Date(), since: since)

        let response: APIResponse<Library>
        do {
            response = try await client.library(since: since)
        } catch {
            status = .failed(.from(error))
            return
        }

        let changes: Changes
        do {
            changes = try apply(response.value, isFull: since == nil)
        } catch {
            // Nothing half-applied survives: roll the context back to the last save.
            context.rollback()
            status = .failed(.storage("The server's changes could not be saved on this iPhone", location: nil, error: error))
            return
        }

        let covers = await refreshCovers(client: client, updatedAlbumIDs: changes.upsertedAlbumIDs)

        var lines = [
            "Request: GET \(response.url.absoluteString), HTTP \(response.status) in \(response.milliseconds) ms",
            since.map { "Delta since \($0) (stored server_time minus \(Self.overlapSeconds) s)" } ?? "Full catalogue (no since)",
            "server_time: \(response.value.serverTime)",
            "Albums: \(changes.albumsInserted) new, \(changes.albumsUpdated) updated, \(changes.albumsDeleted) deleted",
            "Tracks: \(changes.tracksInserted) new, \(changes.tracksUpdated) updated, \(changes.tracksDeleted) deleted",
            "Covers: \(covers.downloaded) downloaded, \(covers.unchanged) unchanged, \(covers.failed) failed",
        ]
        if changes.filesChanged > 0 {
            lines.append("\(changes.filesChanged) track(s) have a new file on the server; their local copies were discarded")
        }
        if covers.failed > 0 {
            lines.append("Failed covers show their error under the album and are retried on the next sync.")
        }
        lines += changes.problems

        record.lastServerTime = response.value.serverTime
        record.lastSyncAt = Date()
        record.lastSummary = lines.joined(separator: "\n")
        do {
            try context.save()
        } catch {
            status = .failed(.storage("The sync result could not be saved on this iPhone", location: nil, error: error))
            return
        }
        status = .succeeded(Date())
    }

    // MARK: - Applying the catalogue

    private struct Changes {
        var albumsInserted = 0
        var albumsUpdated = 0
        var albumsDeleted = 0
        var tracksInserted = 0
        var tracksUpdated = 0
        var tracksDeleted = 0
        var filesChanged = 0
        var upsertedAlbumIDs = Set<Int>()
        var problems: [String] = []
    }

    private func apply(_ library: Library, isFull: Bool) throws -> Changes {
        var changes = Changes()
        let albums = try context.fetch(FetchDescriptor<StoredAlbum>())
        let tracks = try context.fetch(FetchDescriptor<StoredTrack>())
        var albumsByID = Dictionary(albums.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        var tracksByID = Dictionary(tracks.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        var listedTrackIDs = Set<String>()

        for remote in library.albums {
            let album: StoredAlbum
            if let existing = albumsByID[remote.id] {
                album = existing
                changes.albumsUpdated += 1
            } else {
                album = StoredAlbum(serverID: remote.id, artist: remote.artist, title: remote.title)
                context.insert(album)
                albumsByID[remote.id] = album
                changes.albumsInserted += 1
            }
            album.artist = remote.artist
            album.title = remote.title
            album.year = remote.year
            album.palette = remote.palette
            album.updatedAt = remote.updatedAt
            if album.coverURL != remote.coverURL {
                // A different cover path: the stored file and its ETag no longer apply.
                album.coverETag = nil
                if remote.coverURL == nil, let problem = removeCover(of: album) {
                    changes.problems.append(problem)
                }
            }
            album.coverURL = remote.coverURL
            changes.upsertedAlbumIDs.insert(remote.id)

            for remoteTrack in remote.tracks {
                let track: StoredTrack
                if let existing = tracksByID[remoteTrack.id] {
                    track = existing
                    changes.tracksUpdated += 1
                } else {
                    track = StoredTrack(serverID: remoteTrack.id)
                    context.insert(track)
                    tracksByID[remoteTrack.id] = track
                    changes.tracksInserted += 1
                }
                let oldSHA = track.sha256?.lowercased()
                track.title = remoteTrack.title
                track.trackNo = remoteTrack.trackNo
                track.durationS = remoteTrack.durationS
                track.fileBytes = remoteTrack.fileBytes
                track.sha256 = remoteTrack.sha256
                track.updatedAt = remoteTrack.updatedAt
                // Albums arrive with their complete track list, so this also moves
                // a track that changed album.
                track.album = album
                listedTrackIDs.insert(remoteTrack.id)
                if let oldSHA, oldSHA != remoteTrack.sha256?.lowercased() {
                    downloads.serverFileChanged(for: track)
                    changes.filesChanged += 1
                }
            }
        }

        for id in library.deletedTrackIDs {
            guard let track = tracksByID[id] else { continue }
            deleteTrack(track, changes: &changes)
            tracksByID[id] = nil
        }

        var albumIDsToDelete = library.deletedAlbumIDs
        if isFull {
            // A full catalogue is authoritative: anything it does not list is gone.
            let listedAlbumIDs = Set(library.albums.map(\.id))
            albumIDsToDelete += albumsByID.keys.filter { !listedAlbumIDs.contains($0) }
            for (id, track) in tracksByID where !listedTrackIDs.contains(id) {
                deleteTrack(track, changes: &changes)
                tracksByID[id] = nil
            }
        }

        for id in Set(albumIDsToDelete) {
            guard let album = albumsByID[id] else { continue }
            // Tracks the payload moved elsewhere already point at their new album;
            // what is still attached belongs to the deleted album and goes with it.
            for track in album.tracks where !track.isDeleted && !listedTrackIDs.contains(track.serverID) {
                deleteTrack(track, changes: &changes)
            }
            if let problem = removeCover(of: album) {
                changes.problems.append(problem)
            }
            context.delete(album)
            albumsByID[id] = nil
            changes.albumsDeleted += 1
        }

        try context.save()
        return changes
    }

    private func deleteTrack(_ track: StoredTrack, changes: inout Changes) {
        if let problem = downloads.discardLocalData(for: track) {
            changes.problems.append(problem)
        }
        context.delete(track)
        changes.tracksDeleted += 1
    }

    private func removeCover(of album: StoredAlbum) -> String? {
        defer {
            album.coverFileName = nil
            album.coverSavedAt = nil
            album.coverETag = nil
        }
        guard let fileName = album.coverFileName else { return nil }
        do {
            try LocalFiles.removeIfPresent(try LocalFiles.url(.artwork, fileName))
            return nil
        } catch {
            return "Could not delete cover \(fileName) of album \(album.serverID): \(error.localizedDescription)"
        }
    }

    // MARK: - Covers

    /// Downloads covers to Application Support/Artwork, so the library renders
    /// offline. Checks albums that changed, and retries any album whose cover is
    /// missing or failed last time.
    private func refreshCovers(client: APIClient, updatedAlbumIDs: Set<Int>) async -> (downloaded: Int, unchanged: Int, failed: Int) {
        var downloaded = 0
        var unchanged = 0
        var failed = 0

        let albums: [StoredAlbum]
        do {
            albums = try context.fetch(FetchDescriptor<StoredAlbum>())
        } catch {
            downloads.notice("Covers were not checked: the local albums could not be read. \(error.localizedDescription)")
            return (0, 0, 0)
        }

        for album in albums {
            guard let coverURL = album.coverURL else { continue }
            let fileName = LocalFiles.coverFileName(albumID: album.serverID)
            let fileURL: URL
            do {
                fileURL = try LocalFiles.url(.artwork, fileName)
            } catch {
                album.coverError = APIError.storage("Could not create the Artwork folder", location: nil, error: error).fullText
                failed += 1
                continue
            }
            let haveFile = album.coverFileName == fileName && LocalFiles.exists(fileURL)
            guard updatedAlbumIDs.contains(album.serverID) || !haveFile || album.coverError != nil else { continue }

            do {
                let url = try client.resolve(coverURL)
                switch try await client.cover(at: url, etag: haveFile ? album.coverETag : nil) {
                case .notModified:
                    album.coverError = nil
                    unchanged += 1
                case .downloaded(let data, let etag):
                    guard UIImage(data: data) != nil else {
                        throw APIError.undecodableImage(url: url, byteCount: data.count)
                    }
                    do {
                        try data.write(to: fileURL, options: .atomic)
                        try LocalFiles.excludeFromBackup(fileURL)
                    } catch {
                        throw APIError.storage("Could not save the cover", location: fileURL, error: error)
                    }
                    album.coverFileName = fileName
                    album.coverETag = etag
                    album.coverSavedAt = Date()
                    album.coverError = nil
                    downloaded += 1
                }
            } catch {
                album.coverError = APIError.from(error).fullText
                failed += 1
            }
        }
        return (downloaded, unchanged, failed)
    }

    // MARK: - Record

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
}
