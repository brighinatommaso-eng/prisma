import Foundation
import SwiftData

/// Where the copy of a track ends up. Chosen before anything is fetched, and kept
/// with the acquisition, because it decides where the chain stops.
///
/// Streaming does not exist yet, so `server` leaves a track that cannot be played
/// on this phone at all. The row says so rather than pretending otherwise.
enum AcquisitionDestination: String, CaseIterable, Identifiable, Sendable {
    /// The server fetches it, the phone downloads it, then the server deletes its
    /// copy. The phone ends up holding the only one.
    case phone
    /// The server fetches it and keeps it. The phone downloads nothing.
    case server
    /// The server fetches and keeps it, and the phone downloads it too.
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .phone: return "Telefono"
        case .server: return "Server"
        case .both: return "Entrambi"
        }
    }

    var explanation: String {
        switch self {
        case .phone:
            return "Il server lo scarica, poi lo passa al telefono e cancella la sua copia. Occupa spazio solo qui."
        case .server:
            return "Il server lo scarica e lo tiene. Non finisce sul telefono e per ora non si può ascoltare."
        case .both:
            return "Il server lo scarica e lo tiene, e il telefono ne scarica una copia. Si ascolta subito."
        }
    }

    var symbol: String {
        switch self {
        case .phone: return "iphone"
        case .server: return "externaldrive"
        case .both: return "arrow.left.arrow.right"
        }
    }

    /// The phone downloads the file for these two.
    var downloadsToPhone: Bool {
        self != .server
    }
}

/// What is known about a track before anything is fetched: enough to make it a
/// favourite, to show a row while it is acquired, and to ask the server for it.
///
/// Plain values. Built where a row is drawn — from a search result, or from a
/// favourite that has no track — and carried into a sheet and a button that act on
/// it much later, so it holds no model object.
struct AcquisitionRequest: Equatable, Sendable {
    let videoID: String
    let title: String?
    let artist: String?
    let albumName: String?
    let durationS: Int?
    let artworkURL: String?

    var draft: FavouriteDraft {
        FavouriteDraft(
            videoID: videoID,
            title: title,
            artist: artist,
            albumName: albumName,
            artworkURL: artworkURL,
            durationS: durationS
        )
    }

    /// For messages: the title if there is one, the id if there is not.
    var name: String { title ?? videoID }
}

/// Where a track being acquired from Search is in the chain.
enum AcquisitionStage: String, CaseIterable {
    /// POST /downloads not yet confirmed.
    case requesting
    /// The server has a job for it; its state and progress come from GET /downloads.
    case onServer
    /// The server has the track; a library sync brings its hash and size here.
    case syncing
    /// The track is in the local library; the existing device download is starting.
    case handingOff
    /// Destination Telefono only: the file is on the phone and verified, and the
    /// server's copy is being deleted. Never entered before the device download
    /// reached `downloaded`, which is the state the SHA-256 check produces.
    case deletingFromServer
    case failed
}

/// Why an acquisition failed. Recorded where the failure happens, never worked out
/// from the error text, and decides where Riprova picks the chain up again.
enum AcquisitionFailure: String, CaseIterable {
    case noAddress
    case unreachable
    /// The server answered POST or GET /downloads with an error status.
    case serverRejected
    /// The server's reply could not be read.
    case unreadableResponse
    /// The server's job for the track failed: yt-dlp, YouTube, or the backend.
    case serverDownloadFailed
    case serverCancelled
    /// The server no longer lists the job, e.g. its database was replaced.
    case serverLostJob
    case syncFailed
    /// The job finished but the track is not in the library after syncing.
    case notInLibrary
    /// The device download did not start.
    case deviceDownloadRefused
    /// The file is on this phone and verified, but the server would not delete its
    /// copy. Nothing is lost: the track is simply on both.
    case serverDeletionFailed
    case storage
    case unexpected

    /// Which part of the chain it belongs to, for the row subtitle.
    var phase: String {
        switch self {
        case .noAddress, .unreachable, .serverRejected, .unreadableResponse,
             .serverDownloadFailed, .serverCancelled, .serverLostJob, .unexpected:
            return "Non riuscito sul server"
        case .syncFailed, .notInLibrary:
            return "Non riuscito durante la sincronizzazione"
        case .deviceDownloadRefused, .storage:
            return "Non riuscito sul telefono"
        case .serverDeletionFailed:
            return "Sul telefono · copia sul server non rimossa"
        }
    }
}

/// A search result being acquired: it is not in the library yet, so it cannot be a
/// `StoredTrack`. Holds what search already returned, plus its progress through
/// server download, library sync and device download. Deleted once the real track
/// exists and the device download has taken over.
@Model
final class PendingAcquisition {
    @Attribute(.unique) var videoID: String
    var title: String?
    var artist: String?
    var album: String?
    var durationS: Int?
    /// As returned by search: absolute.
    var artworkURL: String?
    var createdAt: Date

    /// Raw value of `stage`; read and write it only through `stage`.
    var stageRaw: String
    var stageChangedAt: Date

    /// Set and saved just before POST /downloads is sent. After a relaunch it means
    /// the server may already have a job, so the job is looked up instead of
    /// requested again, which would queue the track twice.
    var requestSentAt: Date?
    var requestAttempts: Int

    var jobID: Int?
    var serverJobState: String?
    var serverProgress: Double?
    var serverError: String?

    /// Syncs run in the current `syncing` stage without the track appearing.
    var syncAttempts: Int
    /// When the device download was asked for, in the current `handingOff` stage.
    var handoffRequestedAt: Date?

    /// Raw value of `destination`; read and write it only through `destination`.
    /// Optional so an acquisition started by an earlier build, which only ever meant
    /// Entrambi, keeps working across the upgrade.
    var destinationRaw: String?

    /// Attempts at DELETE /tracks/{id} in the current `deletingFromServer` stage.
    /// Declared with its default, so the store this build opens adds the column
    /// with a value rather than needing one written.
    var deletionAttempts: Int = 0

    var failureRaw: String?
    /// The plain-language message, composed when the failure happened.
    var failureMessage: String?
    /// Full error text, kept with the record; the interface shows `failureMessage`.
    var errorText: String?

    init(
        videoID: String,
        title: String?,
        artist: String?,
        album: String?,
        durationS: Int?,
        artworkURL: String?,
        destination: AcquisitionDestination
    ) {
        let now = Date()
        self.videoID = videoID
        self.title = title
        self.artist = artist
        self.album = album
        self.durationS = durationS
        self.artworkURL = artworkURL
        self.createdAt = now
        self.stageRaw = AcquisitionStage.requesting.rawValue
        self.stageChangedAt = now
        self.requestAttempts = 0
        self.syncAttempts = 0
        self.deletionAttempts = 0
        self.destinationRaw = destination.rawValue
    }

    /// Where this acquisition's copy ends up. An acquisition stored by a build that
    /// had no choice behaved as Entrambi, so that is what it reads as.
    var destination: AcquisitionDestination {
        get { destinationRaw.flatMap { AcquisitionDestination(rawValue: $0) } ?? .both }
        set { destinationRaw = newValue.rawValue }
    }

    var stage: AcquisitionStage {
        get {
            // Only this app writes the raw value; an unknown one is shown as failed
            // rather than silently resumed.
            AcquisitionStage(rawValue: stageRaw) ?? .failed
        }
        set {
            stageRaw = newValue.rawValue
            stageChangedAt = Date()
            if newValue != .failed {
                failureRaw = nil
                failureMessage = nil
                errorText = nil
            }
        }
    }

    var failure: AcquisitionFailure? {
        get { failureRaw.flatMap { AcquisitionFailure(rawValue: $0) } }
        set { failureRaw = newValue?.rawValue }
    }

    var isActive: Bool {
        stage != .failed
    }
}
