import Foundation
import SwiftUI
import UIKit

/// Everything the download machinery knows about a track: sizes, the pre-flight
/// check, how long it has waited, what iOS last reported, progress in bytes and the
/// last automatic action. Developer information, shown behind
/// "Mostra dettagli tecnici"; failures and refusals are shown by `TrackProblems`.
struct TrackTechnicalDetails: View {
    let track: StoredTrack

    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stateLine)
                .textSelection(.enabled)

            if let since = downloads.preflights[track.serverID] {
                LoadingRow(
                    message: "Pre-flight: checking the server can serve this file…",
                    since: since,
                    timeout: APIClient.Timeout.probe
                )
            } else if track.downloadState == .queued {
                queuedView
            } else if track.downloadState == .downloading {
                progressView
            }

            if let note = track.note {
                Text(note)
            }

            if let target = track.targetAddress {
                Text("Server address for this attempt: \(target)")
                    .textSelection(.enabled)
            }
        }
        .font(.caption2.monospaced())
    }

    private var stateLine: String {
        switch track.downloadState {
        case .downloaded:
            return "Downloaded, \(Formatting.bytes(track.storedBytes))"
        case .notDownloaded:
            return "Not downloaded, \(Formatting.bytes(track.fileBytes))"
        default:
            return "\(track.downloadState.label), \(Formatting.bytes(track.fileBytes))"
        }
    }

    /// Queued: how long this attempt has waited, what iOS last said, and when it
    /// will give up.
    @ViewBuilder
    private var queuedView: some View {
        if let started = track.attemptStartedAt {
            TimelineView(.periodic(from: started, by: 1)) { context in
                let waited = Int(context.date.timeIntervalSince(started))
                Text("Waiting \(Formatting.elapsed(waited)) for iOS to start the transfer. If no data arrives within \(Int(DownloadManager.startDeadline / 60)) min it fails as never started.")
            }
        } else {
            Text("Queued, but no start time was recorded for this attempt.")
        }
        Text("Last problem reported by iOS: \(track.lastSessionError ?? "none so far")")
        if let summary = track.preflightSummary {
            Text(summary)
                .textSelection(.enabled)
        }
        if let queuedAt = track.queuedAt {
            Text("In the queue since \(Formatting.time(queuedAt)).")
        }
    }

    @ViewBuilder
    private var progressView: some View {
        if let token = track.downloadToken, let progress = downloads.progress[token], progress.expected > 0 {
            Text("\(Int((Double(progress.received) / Double(progress.expected) * 100).rounded()))%: \(Formatting.bytes(Int(progress.received))) of \(Formatting.bytes(Int(progress.expected)))")
        } else {
            Text("No progress reported since the app opened; the transfer is running in the background.")
        }
    }
}

/// An album cover read from Application Support/Artwork. Never touches the network.
/// Without a file it draws a neutral tile with a note glyph; an unreadable file is
/// reported through `problem`.
struct LocalCoverImage: View {
    let album: StoredAlbum
    let side: CGFloat
    @Binding var problem: String?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            CoverPlaceholder(palette: album.palette, side: side)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: loadKey) {
            load()
        }
        .accessibilityHidden(true)
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

/// A cover-sized tile: the album's palette as a gradient when it has one, a
/// neutral fill otherwise, with a note glyph.
struct CoverPlaceholder: View {
    let palette: [String]?
    let side: CGFloat

    var body: some View {
        let colors = (palette ?? []).compactMap { RGBColor(hex: $0) }
            .map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        ZStack {
            if colors.count >= 2 {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Rectangle().fill(Color.gray.opacity(0.35))
            }
            Image(systemName: "music.note")
                .font(.system(size: max(10, side * 0.3), weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .frame(width: side, height: side)
    }
}

/// A local cover, or the placeholder for a track without an album, with rounded
/// corners.
struct CoverArt: View {
    let album: StoredAlbum?
    let side: CGFloat
    let cornerRadius: CGFloat

    @State private var problem: String?

    var body: some View {
        Group {
            if let album {
                LocalCoverImage(album: album, side: side, problem: $problem)
            } else {
                CoverPlaceholder(palette: nil, side: side)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// The 2×2 cover of a playlist, from the first four distinct albums in playlist
/// order. With fewer albums the covers repeat across the grid.
struct PlaylistMosaic: View {
    let playlist: Playlist
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let albums = Self.distinctAlbums(in: playlist)
        let cell = side / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tile(albums, 0, cell)
                tile(albums, 1, cell)
            }
            HStack(spacing: 0) {
                tile(albums, 2, cell)
                tile(albums, 3, cell)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(_ albums: [StoredAlbum], _ index: Int, _ cell: CGFloat) -> some View {
        if albums.isEmpty {
            CoverPlaceholder(palette: nil, side: cell)
        } else {
            // Two albums sit on the diagonal; three repeat the first in the corner.
            let order: [Int] = albums.count == 2 ? [0, 1, 1, 0] : [0, 1, 2, 0]
            let pick = albums.count >= 4 ? index : order[index] % albums.count
            CoverArt(album: albums[pick], side: cell, cornerRadius: 0)
        }
    }

    static func distinctAlbums(in playlist: Playlist) -> [StoredAlbum] {
        var seen = Set<Int>()
        var result: [StoredAlbum] = []
        for entry in PlaylistStore.orderedEntries(of: playlist) {
            guard let album = entry.track?.album, !album.isDeleted, seen.insert(album.serverID).inserted else { continue }
            result.append(album)
            if result.count == 4 { break }
        }
        return result
    }
}
