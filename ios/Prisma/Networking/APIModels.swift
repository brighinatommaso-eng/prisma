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

    nonisolated enum CodingKeys: String, CodingKey {
        case ytdlpVersion = "ytdlp_version"
        case ytmusicapiVersion = "ytmusicapi_version"
        case musicFreeBytes = "music_free_bytes"
        case youtubeMusicReachable = "youtube_music_reachable"
        case trackCount = "track_count"
        case albumCount = "album_count"
        case totalBytesStored = "total_bytes_stored"
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
