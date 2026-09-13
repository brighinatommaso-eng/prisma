import Foundation
import SwiftData

/// Per-track download state. Stored as its raw value in `StoredTrack`.
enum DownloadState: String, CaseIterable {
    case notDownloaded
    case queued
    case downloading
    case downloaded
    case failed
    case cancelled

    var label: String {
        switch self {
        case .notDownloaded: return "Not downloaded"
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .downloaded: return "Downloaded"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Mirror of one album from /library.
@Model
final class StoredAlbum {
    @Attribute(.unique) var serverID: Int
    var artist: String
    var title: String
    var year: Int?
    var palette: [String]?
    /// As sent by the server: relative, resolved against the saved address.
    var coverURL: String?
    var updatedAt: Int?

    /// Name of the cover file in Application Support/Artwork, once downloaded.
    var coverFileName: String?
    var coverETag: String?
    var coverSavedAt: Date?
    /// Full error text of the last failed cover download, nil once it succeeds.
    var coverError: String?

    @Relationship(deleteRule: .nullify, inverse: \StoredTrack.album)
    var tracks: [StoredTrack] = []

    init(serverID: Int, artist: String, title: String) {
        self.serverID = serverID
        self.artist = artist
        self.title = title
    }
}

/// Mirror of one track from /library, plus its local download state.
@Model
final class StoredTrack {
    @Attribute(.unique) var serverID: String
    var title: String?
    var trackNo: Int?
    var durationS: Int?
    var fileBytes: Int?
    var sha256: String?
    var updatedAt: Int?
    var album: StoredAlbum?

    var downloadStateRaw: String
    var stateChangedAt: Date?
    /// Identifies the current download attempt. Travels in the URLSession task's
    /// description, so an event from an older attempt can be recognised.
    var downloadToken: String?
    var taskIdentifier: Int?
    var queuedAt: Date?
    /// Full error text while `failed`.
    var errorText: String?
    /// Informational line about the last automatic action, e.g. a restart.
    var note: String?
    /// Name of the audio file in Application Support/Music while `downloaded`.
    var fileName: String?
    var storedBytes: Int?
    /// From a failed or interrupted transfer, so a retry can continue from there.
    @Attribute(.externalStorage) var resumeData: Data?

    init(serverID: String) {
        self.serverID = serverID
        self.downloadStateRaw = DownloadState.notDownloaded.rawValue
    }

    var downloadState: DownloadState {
        get {
            // Only this app writes the raw value. An unknown one would be a bug,
            // so it is shown as failed rather than hidden as not downloaded.
            DownloadState(rawValue: downloadStateRaw) ?? .failed
        }
        set {
            downloadStateRaw = newValue.rawValue
            stateChangedAt = Date()
        }
    }
}

/// The single row holding sync bookkeeping.
@Model
final class SyncRecord {
    /// `server_time` from the last applied /library response.
    var lastServerTime: Int?
    var lastSyncAt: Date?
    var lastSummary: String?

    init() {}
}
