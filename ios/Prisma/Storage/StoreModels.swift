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
        case .notDownloaded: return "Non scaricato"
        case .queued: return "In coda"
        case .downloading: return "In download"
        case .downloaded: return "Scaricato"
        case .failed: return "Non riuscito"
        case .cancelled: return "Annullato"
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
            return "recuperabile con un cambio di indirizzo"
        case .httpStatus:
            return "il server non ha il file"
        case .verification:
            return "il file ricevuto era danneggiato"
        case .storage:
            return "spazio insufficiente o salvataggio non riuscito"
        case .missingServerData:
            return "il server non ha fornito i dati del file, serve sincronizzare la libreria"
        case .serverFileChanged:
            return "il file sul server è cambiato durante il download"
        case .fileMissing:
            return "il file scaricato non è più sul telefono"
        case .systemCancelled:
            return "iOS ha interrotto il trasferimento"
        case .other:
            return "un errore che non dipende dall'indirizzo"
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

    /// Mirror of `FavouriteTrack`, kept in step by `PlaylistStore`.
    ///
    /// The collection itself is `FavouriteTrack`, keyed by video id, because a
    /// favourite may exist with no track anywhere. This flag stays because every
    /// row projection already reads it, and because a build installed before the
    /// collection existed still reads favourites from here.
    var favouritedAt: Date?

    /// When this phone asked the server to drop its copy, so that this phone could
    /// own the only one (the Telefono destination). Written and saved *before*
    /// `DELETE /tracks/{id}` is sent, never after: between the two the server may
    /// answer, a delta sync may arrive, and `LibrarySync` must already know that
    /// the deletion it is being told about is one this phone asked for.
    ///
    /// nil on every track the server owns, which is every track of the library that
    /// existed before this build.
    var phoneOnlySince: Date?

    /// When a sync actually saw the server drop this track while `phoneOnlySince`
    /// was set. The intent above is what stops the file being discarded; this is
    /// the fact, and it is what the interface reads: a track whose server copy is
    /// confirmed gone is "non acquisito" once its file leaves the phone.
    ///
    /// Cleared, together with `phoneOnlySince`, when the server lists the track
    /// again — `POST /downloads` revives a soft-deleted track, and then the server
    /// owns it once more.
    var serverDroppedAt: Date?

    /// Every playlist entry pointing at this track. Deleting the track (as a sync
    /// does when the server removes it) deletes these entries with it, so no
    /// playlist can keep a reference to a track that no longer exists.
    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.track)
    var playlistEntries: [PlaylistEntry] = []

    init(serverID: String) {
        self.serverID = serverID
        self.downloadStateRaw = DownloadState.notDownloaded.rawValue
    }

    var isFavourite: Bool {
        favouritedAt != nil
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

/// One track in Preferiti: the collection, keyed by the YouTube video id.
///
/// Its own row rather than a flag on `StoredTrack`, because a favourite may exist
/// with no track anywhere. Adding one from Cerca with the plus stores exactly what
/// search returned — video id, title, artist, album name, artwork URL — and
/// downloads nothing, so the favourite is real before the audio is.
///
/// The video id is the same id `StoredTrack.serverID` uses, so a favourite and a
/// library track are matched by comparing two strings and reading neither row.
/// Nothing in the sync writes here: the server has no idea what is favourited, and
/// deleting a track from the server leaves its favourite behind on purpose.
@Model
final class FavouriteTrack {
    @Attribute(.unique) var videoID: String
    /// What search or the library knew when it was added, so a favourite with no
    /// track still has a line to show.
    var title: String?
    var artist: String?
    var albumName: String?
    /// Absolute, as search returned it. Only used while no local album cover exists.
    var artworkURL: String?
    var durationS: Int?
    /// Newest first is the order of Preferiti.
    var addedAt: Date

    init(
        videoID: String,
        title: String?,
        artist: String?,
        albumName: String?,
        artworkURL: String?,
        durationS: Int?,
        addedAt: Date = Date()
    ) {
        self.videoID = videoID
        self.title = title
        self.artist = artist
        self.albumName = albumName
        self.artworkURL = artworkURL
        self.durationS = durationS
        self.addedAt = addedAt
    }
}

/// Everything needed to create a favourite, as plain values.
///
/// A row builds one while it is drawn and hands it to a button, a menu or a sheet,
/// which act on it long afterwards — so it holds no model object, and the store
/// reads nothing back to create the favourite except the favourite itself.
struct FavouriteDraft: Equatable, Sendable {
    let videoID: String
    let title: String?
    let artist: String?
    let albumName: String?
    let artworkURL: String?
    let durationS: Int?
}

/// A user playlist, stored only on this iPhone.
@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    /// The user's order of playlists, set explicitly when they reorder.
    var sortPosition: Int

    @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.playlist)
    var entries: [PlaylistEntry] = []

    init(name: String, sortPosition: Int) {
        let now = Date()
        self.id = UUID()
        self.name = name
        self.createdAt = now
        self.updatedAt = now
        self.sortPosition = sortPosition
    }
}

/// One slot in a playlist. Its own row, so the same track can appear more than
/// once, and the order is the stored `position`, never insertion time.
///
/// A slot names its track twice over, and the two are not the same thing:
///
/// - `track` is the library row, when there is one. It carries the download state
///   and the album, and the cascade on `StoredTrack.playlistEntries` means the slot
///   dies with it when the server drops the track.
/// - `videoID` is the YouTube video id, which is what `FavouriteTrack` is keyed by
///   and what `StoredTrack.serverID` holds. It is the *name* of the track, and it
///   exists even when nothing has been downloaded anywhere.
///
/// The second was added because a playlist can now be filled from Cerca, and a
/// result chosen there has no library row at all — exactly the case `FavouriteTrack`
/// was created for. A slot like that carries only the id until the track is
/// acquired; `PlaylistStore.entries(of:)` links it to its library row the first time
/// it sees one, and from that moment it behaves like every other slot, cascade
/// included.
///
/// Optional because entries written by earlier builds have no id recorded; they
/// have a `track`, and everything that needs an id falls back to its `serverID`.
@Model
final class PlaylistEntry {
    @Attribute(.unique) var id: UUID
    var position: Int
    var addedAt: Date
    var playlist: Playlist?
    var track: StoredTrack?
    var videoID: String?

    init(position: Int, playlist: Playlist, track: StoredTrack) {
        self.id = UUID()
        self.position = position
        self.addedAt = Date()
        self.playlist = playlist
        self.track = track
        self.videoID = track.serverID
    }

    /// A slot for a track that is in no library yet: chosen from Cerca, added to
    /// Preferiti in the same action, and downloaded whenever the user decides.
    init(position: Int, playlist: Playlist, videoID: String) {
        self.id = UUID()
        self.position = position
        self.addedAt = Date()
        self.playlist = playlist
        self.track = nil
        self.videoID = videoID
    }

    /// What this slot names, however it was created.
    var trackID: String? {
        videoID ?? track?.serverID
    }
}

/// The single row holding sync bookkeeping.
@Model
final class SyncRecord {
    /// `server_time` from the last applied /library response.
    var lastServerTime: Int?
    var lastSyncAt: Date?
    var lastSummary: String?

    /// When the one-off pass that made every track already on this phone a
    /// favourite finished. nil means it has not run: it runs at the next launch.
    /// Kept here because this row already exists exactly once.
    var favouritesMigratedAt: Date?

    init() {}
}
