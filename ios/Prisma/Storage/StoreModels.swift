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

/// Why a track is in the `failed` state. Recorded where the failure happens,
/// never worked out afterwards from the error text.
enum FailureCause: String, CaseIterable {
    /// The server could not be reached: a URLError from the pre-flight check or
    /// from the transfer itself.
    case unreachable
    /// Handed to iOS, but no data arrived before the start deadline.
    case neverStarted
    /// No valid server address was saved when the download was attempted.
    case noAddress
    /// The server answered with an error status, e.g. 404 or 410.
    case httpStatus
    /// The received file did not match its SHA-256.
    case verification
    /// Not enough free space, or a file operation failed.
    case storage
    /// The server gave no SHA-256 or file size for the track.
    case missingServerData
    /// The server's copy of the file changed during the download.
    case serverFileChanged
    /// The track was marked downloaded but its file was gone.
    case fileMissing
    /// iOS cancelled the transfer, e.g. Background App Refresh is off.
    case systemCancelled
    case other

    /// Failures a different server address can fix. Saving a new address
    /// retries exactly these.
    var isAddressRelated: Bool {
        switch self {
        case .unreachable, .neverStarted, .noAddress:
            return true
        case .httpStatus, .verification, .storage, .missingServerData, .serverFileChanged,
             .fileMissing, .systemCancelled, .other:
            return false
        }
    }

    /// Why an address change leaves a failure of this kind alone.
    var notRevivedReason: String {
        switch self {
        case .unreachable, .neverStarted, .noAddress:
            return "revived by an address change"
        case .httpStatus:
            return "the server answered with an error status such as 404, so it does not have the file"
        case .verification:
            return "the file failed SHA-256 verification, which an address cannot fix"
        case .storage:
            return "not enough free space or a file could not be written"
        case .missingServerData:
            return "the server gave no SHA-256 or file size; sync the library first"
        case .serverFileChanged:
            return "the server's file changed during the download"
        case .fileMissing:
            return "the downloaded file disappeared from this iPhone"
        case .systemCancelled:
            return "iOS cancelled the transfer"
        case .other:
            return "an error unrelated to reaching the server"
        }
    }

    /// Classifies an error by its typed kind.
    static func of(_ error: APIError) -> FailureCause {
        switch error.kind {
        case .transport:
            return .unreachable
        case .notConfigured, .invalidAddress:
            return .noAddress
        case .http:
            return .httpStatus
        case .verification:
            return .verification
        case .storage:
            return .storage
        case .invalidInput, .cancelled, .invalidResponse, .decoding, .notAnImage, .unexpected:
            return .other
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
    /// When the track first entered the queue. Kept when an attempt is replaced,
    /// so re-targeted downloads keep their order.
    var queuedAt: Date?
    /// When the current background task was created. The start deadline counts from here.
    var attemptStartedAt: Date?
    /// The server address the current or last attempt was built against.
    var targetAddress: String?
    /// Result of the pre-flight check for the current attempt.
    var preflightSummary: String?
    /// The last problem iOS reported about the current attempt while it waited.
    var lastSessionError: String?
    /// Full error text while `failed`.
    var errorText: String?
    /// Raw value of `failureCause`. Stored raw, like `downloadStateRaw`; read and
    /// write it only through `failureCause`.
    var failureCauseRaw: String?
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
            // A cause only describes the current failure.
            if newValue != .failed {
                failureCauseRaw = nil
            }
        }
    }

    /// Why the track failed; nil while not failed, and for failures recorded
    /// before causes existed.
    var failureCause: FailureCause? {
        get { failureCauseRaw.flatMap { FailureCause(rawValue: $0) } }
        set { failureCauseRaw = newValue?.rawValue }
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
