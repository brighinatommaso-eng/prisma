import Foundation
import SwiftUI
import UIKit

/// A track's download state, progress, errors and the actions available in that
/// state. Used by both the Library and Downloads tabs.
struct TrackDownloadStatus: View {
    let track: StoredTrack
    /// Downloads tab: also show when the track first entered the queue.
    var showTiming = false

    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stateLine)
                .font(.caption)

            if let since = downloads.preflights[track.serverID] {
                LoadingRow(
                    message: "Pre-flight: checking the server can serve this file…",
                    since: since,
                    timeout: APIClient.Timeout.probe
                )
                .font(.caption)
            } else if track.downloadState == .queued {
                queuedView
            } else if track.downloadState == .downloading {
                progressView
            }

            if let note = track.note {
                Text(note)
                    .font(.caption2)
            }

            if track.downloadState == .failed, let errorText = track.errorText {
                ErrorReport(storedText: errorText)
            }

            if let refusal = downloads.refusals[track.serverID] {
                ErrorReport(error: refusal)
            }

            // No actions while a pre-flight runs: its result decides the state.
            if downloads.preflights[track.serverID] == nil {
                actions
            }
        }
    }

    private var stateLine: String {
        switch track.downloadState {
        case .downloaded:
            return "Downloaded, \(Formatting.bytes(track.storedBytes))"
        case .notDownloaded:
            return "Not downloaded, \(Formatting.bytes(track.fileBytes))"
        default:
            return track.downloadState.label
        }
    }

    /// Queued: how long this attempt has waited, what iOS last said, and when it
    /// will give up, so waiting is never silent.
    @ViewBuilder
    private var queuedView: some View {
        if let started = track.attemptStartedAt {
            TimelineView(.periodic(from: started, by: 1)) { context in
                let waited = Int(context.date.timeIntervalSince(started))
                Text("Waiting \(Formatting.elapsed(waited)) for iOS to start the transfer. If no data arrives within \(Int(DownloadManager.startDeadline / 60)) min it fails as never started.")
                    .font(.caption2.monospacedDigit())
            }
        } else {
            Text("Queued, but no start time was recorded for this attempt.")
                .font(.caption2)
        }
        Text("Last problem reported by iOS: \(track.lastSessionError ?? "none so far")")
            .font(.caption2)
        if let summary = track.preflightSummary {
            Text(summary)
                .font(.caption2)
                .textSelection(.enabled)
        }
        if showTiming, let queuedAt = track.queuedAt {
            Text("In the queue since \(Formatting.time(queuedAt)).")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var progressView: some View {
        if let token = track.downloadToken, let progress = downloads.progress[token], progress.expected > 0 {
            ProgressView(value: min(1, Double(progress.received) / Double(progress.expected)))
            Text("\(Int((Double(progress.received) / Double(progress.expected) * 100).rounded()))%: \(Formatting.bytes(Int(progress.received))) of \(Formatting.bytes(Int(progress.expected)))")
                .font(.caption2.monospacedDigit())
        } else {
            Text("No progress reported since the app opened; the transfer is running in the background.")
                .font(.caption2)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 20) {
            switch track.downloadState {
            case .notDownloaded:
                Button("Download") { downloads.download(track) }
            case .queued, .downloading:
                Button("Cancel") { downloads.cancel(track) }
            case .downloaded:
                Button("Remove from device") { downloads.removeFile(track) }
            case .failed, .cancelled:
                Button("Retry") { downloads.download(track) }
                Button("Dismiss") { downloads.dismiss(track) }
            }
        }
        .buttonStyle(.borderless)
    }
}

/// An album cover read from Application Support/Artwork. Never touches the network.
struct LocalCoverImage: View {
    let album: StoredAlbum
    let side: CGFloat
    @Binding var problem: String?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if album.coverFileName == nil {
                Text(album.coverURL == nil ? "no cover" : "not saved")
                    .font(.caption2)
            } else {
                Image(systemName: "exclamationmark.triangle")
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: loadKey) {
            load()
        }
    }

    /// Changes whenever a new cover file is saved, so the image reloads.
    private var loadKey: String {
        "\(album.coverFileName ?? "-")|\(album.coverSavedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func load() {
        image = nil
        problem = nil
        guard let fileName = album.coverFileName else { return }
        do {
            let url = try LocalFiles.url(.artwork, fileName)
            guard let loaded = UIImage(contentsOfFile: url.path(percentEncoded: false)) else {
                problem = "The cover file \(fileName) is missing or unreadable. It is downloaded again on the next sync."
                return
            }
            image = loaded
        } catch {
            problem = APIError.from(error).fullText
        }
    }
}
