import Foundation

// Mirrors the Pydantic models in backend/app/main.py. Optionals match the
// backend's `| None` fields exactly. CodingKeys use the JSON names, so a decoding
// error on screen names the same field you would see in the raw response.

nonisolated struct Health: Decodable, Sendable {
    let ytdlpVersion: String
    let ytmusicapiVersion: String
    let musicFreeBytes: Int
    let youtubeMusicReachable: Bool
    let trackCount: Int
    let albumCount: Int
    let totalBytesStored: Int
    /// Whether the server's download queue is resting after YouTube's bot wall, and
    /// until when (Unix seconds; nil while it is not). Optional, both of them: a
    /// backend from before the cooldown existed does not send either, and its
    /// /health must still decode.
    let downloadCooldownActive: Bool?
    let downloadCooldownUntil: Int?

    nonisolated enum CodingKeys: String, CodingKey {
        case ytdlpVersion = "ytdlp_version"
        case ytmusicapiVersion = "ytmusicapi_version"
        case musicFreeBytes = "music_free_bytes"
        case youtubeMusicReachable = "youtube_music_reachable"
        case trackCount = "track_count"
        case albumCount = "album_count"
        case totalBytesStored = "total_bytes_stored"
        case downloadCooldownActive = "download_cooldown_active"
        case downloadCooldownUntil = "download_cooldown_until"
    }

    /// When the queue starts again, or nil when it is not resting — which is also
    /// what an older backend, a cooldown with no end, and an end already in the
    /// past all read as.
    var downloadCooldownEnd: Date? {
        guard downloadCooldownActive == true, let downloadCooldownUntil else { return nil }
        let end = Date(timeIntervalSince1970: TimeInterval(downloadCooldownUntil))
        return end > Date() ? end : nil
    }
}

nonisolated struct SongResult: Decodable, Sendable {
    let videoID: String
    let title: String?
    let artist: String?
    let album: String?
    let durationS: Int?
    let artworkURL: String?
    let artworkURLSmall: String?

    nonisolated enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case title
        case artist
        case album
        case durationS = "duration_s"
        case artworkURL = "artwork_url"
        case artworkURLSmall = "artwork_url_small"
    }
}

nonisolated struct Library: Decodable, Sendable {
    let serverTime: Int
    let since: Int?
    let albums: [LibraryAlbum]
    let deletedAlbumIDs: [Int]
    let deletedTrackIDs: [String]

    nonisolated enum CodingKeys: String, CodingKey {
        case serverTime = "server_time"
        case since
        case albums
        case deletedAlbumIDs = "deleted_album_ids"
        case deletedTrackIDs = "deleted_track_ids"
    }
}

nonisolated struct LibraryAlbum: Decodable, Sendable, Identifiable {
    let id: Int
    let artist: String
    let title: String
    let year: Int?
    let palette: [String]?
    /// Relative, e.g. "/albums/3/cover". Resolve with `APIClient.resolve`.
    let coverURL: String?
    let updatedAt: Int?
    let tracks: [LibraryTrack]

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case artist
        case title
        case year
        case palette
        case coverURL = "cover_url"
        case updatedAt = "updated_at"
        case tracks
    }
}

nonisolated struct LibraryTrack: Decodable, Sendable, Identifiable {
    let id: String
    let title: String?
    let trackNo: Int?
    let durationS: Int?
    let fileBytes: Int?
    let sha256: String?
    let updatedAt: Int?

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case title
        case trackNo = "track_no"
        case durationS = "duration_s"
        case fileBytes = "file_bytes"
        case sha256
        case updatedAt = "updated_at"
    }
}

/// Reply to POST /import/demus: a playlist exported by the Demus app, as the server
/// read it. The server only parses the file; nothing there changes.
nonisolated struct DemusPlaylist: Decodable, Sendable, Equatable {
    let name: String
    /// Unix seconds, from the export; nil when it carried no date.
    let createdAt: Int?
    /// In the playlist's order. A song listed twice in the file appears twice.
    let songs: [DemusSong]

    nonisolated enum CodingKeys: String, CodingKey {
        case name
        case createdAt = "created_at"
        case songs
    }
}

nonisolated struct DemusSong: Decodable, Sendable, Equatable {
    /// The YouTube video id: the key of a favourite, of a library track and of
    /// POST /downloads alike.
    let videoID: String
    let title: String?
    let artist: String?
    let album: String?
    let artworkURL: String?
    let durationS: Int?

    nonisolated enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case title
        case artist
        case album
        case artworkURL = "artwork_url"
        case durationS = "duration_s"
    }
}

/// Reply to POST /downloads: 202 with a queued job, or 200 with the track the
/// server already has.
nonisolated struct DownloadRequestResult: Decodable, Sendable {
    let status: String
    let jobID: Int?
    let track: ExistingServerTrack?

    nonisolated enum CodingKeys: String, CodingKey {
        case status
        case jobID = "job_id"
        case track
    }
}

/// Only the id is read from the stored track the server returns; the track itself
/// arrives through /library.
nonisolated struct ExistingServerTrack: Decodable, Sendable {
    let id: String
}

/// Reply to DELETE /tracks/{id}. Only `status` is read; the rest is decoded so the
/// raw response stays inspectable, and optional so a detail the backend drops later
/// cannot fail a deletion that succeeded.
nonisolated struct TrackDeletionResult: Decodable, Sendable {
    let trackID: String?
    /// "deleted" or "already_deleted".
    let status: String
    let bytesFreed: Int?
    let albumID: Int?
    let albumRemoved: Bool?
    let albumFolderRemoved: Bool?
    let unexpectedFiles: [String]?

    nonisolated enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case status
        case bytesFreed = "bytes_freed"
        case albumID = "album_id"
        case albumRemoved = "album_removed"
        case albumFolderRemoved = "album_folder_removed"
        case unexpectedFiles = "unexpected_files"
    }
}

/// One row of GET /downloads.
nonisolated struct ServerJob: Decodable, Sendable {
    let id: Int
    /// The video id the job downloads.
    let trackID: String?
    let state: String
    let progress: Double
    let error: String?
    let createdAt: Int
    let updatedAt: Int?

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case trackID = "track_id"
        case state
        case progress
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// backend/app/db.py job states.
    nonisolated enum State: String, Sendable {
        case queued
        case running
        case done
        case failed
        case cancelled
    }

    var knownState: State? {
        State(rawValue: state)
    }
}
