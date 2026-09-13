import Foundation
import SwiftData
import SwiftUI

/// The download queue, rendered from the local store. No network call.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads

    @Query private var tracks: [StoredTrack]

    private let sectionOrder: [DownloadState] = [.downloading, .queued, .failed, .cancelled, .downloaded]

    var body: some View {
        List {
            Section {
                if downloads.isChecking {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Checking transfers…")
                    }
                }
                if let count = downloads.liveTransferCount, let checked = downloads.lastCheck {
                    Text("iOS reported \(count) transfer(s) in progress at \(Formatting.time(checked)).")
                } else {
                    Text("Transfers not checked yet.")
                }
                Button("Check transfers now") {
                    downloads.checkTransfers(reason: "manual check")
                }
                .disabled(downloads.isChecking)
            } header: {
                Text("Background transfers").textCase(nil)
            } footer: {
                Text("The check restarts transfers iOS has lost, e.g. after the app was closed from the app switcher. It waits a few seconds first so finished transfers are recorded, not restarted.")
            }

            if !downloads.notices.isEmpty {
                Section {
                    ForEach(downloads.notices) { notice in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Formatting.time(notice.date))
                                .font(.caption)
                            Text(notice.text)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    Button("Clear notices") { downloads.clearNotices() }
                } header: {
                    Text("Notices").textCase(nil)
                }
            }

            if tracks.allSatisfy({ $0.downloadState == .notDownloaded }) {
                Section {
                    Text("No downloads yet. Pick tracks in the Library tab.")
                }
            }

            ForEach(sectionOrder, id: \.self) { state in
                let matching = items(in: state)
                if !matching.isEmpty {
                    Section {
                        ForEach(matching) { track in
                            DownloadRow(track: track)
                        }
                    } header: {
                        Text("\(state.label) (\(matching.count))").textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Downloads")
    }

    private func items(in state: DownloadState) -> [StoredTrack] {
        tracks
            .filter { $0.downloadState == state }
            .sorted { ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast) }
    }
}

private struct DownloadRow: View {
    let track: StoredTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(track.title ?? "(no title)")
            Text([track.album?.artist, track.album?.title].compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
            TrackDownloadStatus(track: track, showTiming: true)
        }
    }
}
