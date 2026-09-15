import Foundation
import SwiftData

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

    var failureRaw: String?
    /// The plain-language message, composed when the failure happened.
    var failureMessage: String?
    /// Full error text, for "Mostra dettagli tecnici".
    var errorText: String?

    init(videoID: String, title: String?, artist: String?, album: String?, durationS: Int?, artworkURL: String?) {
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
