import Foundation
import SwiftUI
import UIKit

/// A track's download state, progress, errors and the actions available in that
/// state. Used by both the Library and Downloads tabs.
struct TrackDownloadStatus: View {
    let track: StoredTrack
    /// Downloads tab: also show how long a queued item has been waiting.
    var showTiming = false

    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stateLine)
                .font(.caption)

            if track.downloadState == .queued || track.downloadState == .downloading {
                progressView
            }

            if let note = track.note {
                Text(note)
                    .font(.caption2)
            }

            if track.downloadState == .failed, let errorText = track.errorText {
                Text(errorText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy error text") {
                    UIPasteboard.general.string = errorText
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if let refusal = downloads.refusals[track.serverID] {
                ErrorReport(error: refusal)
            }

            actions
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

    @ViewBuilder
    private var progressView: some View {
        if let token = track.downloadToken, let progress = downloads.progress[token], progress.expected > 0 {
            ProgressView(value: min(1, Double(progress.received) / Double(progress.expected)))
            Text("\(Int((Double(progress.received) / Double(progress.expected) * 100).rounded()))%: \(Formatting.bytes(Int(progress.received))) of \(Formatting.bytes(Int(progress.expected)))")
                .font(.caption2.monospacedDigit())
        } else {
            Text(track.downloadState == .queued
                 ? "Waiting for iOS to start the transfer."
                 : "No progress reported since the app opened; the transfer is running in the background.")
                .font(.caption2)
        }
        if showTiming, let queuedAt = track.queuedAt {
            TimelineView(.periodic(from: queuedAt, by: 1)) { context in
                Text("Queued \(Int(context.date.timeIntervalSince(queuedAt)))s ago. iOS gives up after \(Int(DownloadManager.transferTimeout / 60)) min without finishing.")
                    .font(.caption2.monospacedDigit())
            }
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
