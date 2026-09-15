import Foundation
import SwiftData
import SwiftUI

/// The download queue, rendered from the local store. No network call.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.prismaInk) private var ink

    @Query private var tracks: [StoredTrack]

    var body: some View {
        let inProgress = items(in: [.downloading, .queued])
        let failed = items(in: [.failed])
        let cancelled = items(in: [.cancelled])
        let downloaded = items(in: [.downloaded])

        List {
            if inProgress.isEmpty && failed.isEmpty && cancelled.isEmpty && downloaded.isEmpty {
                Text("Nessun download. Tocca la freccia accanto a un brano in Libreria.")
                    .font(.subheadline)
                    .foregroundStyle(ink.secondary)
                    .padding(.vertical, 16)
                    .prismaRow()
                    .listRowSeparator(.hidden)
            }

            group("In corso", inProgress)
            group("Non riuscito", failed)
            group("Annullati", cancelled)
            group("Scaricati", downloaded)

            TechnicalDetailsSection {
                transferDetails
            }
            .padding(.top, 12)
            .prismaRow()
            .listRowSeparator(.hidden)
        }
        .prismaList()
        .navigationTitle("Download")
    }

    @ViewBuilder
    private func group(_ title: String, _ matching: [StoredTrack]) -> some View {
        if !matching.isEmpty {
            SectionLabel(title)
                .prismaRow()
                .listRowSeparator(.hidden, edges: .top)
            ForEach(matching) { track in
                DownloadRow(track: track)
                    .prismaRow()
            }
        }
    }

    /// Background transfer checks and notices: developer information.
    @ViewBuilder
    private var transferDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Button("Controlla trasferimenti ora") {
                downloads.checkTransfers(reason: "manual check")
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
            .disabled(downloads.isChecking)
            Text("The check restarts transfers iOS has lost, e.g. after the app was closed from the app switcher. It waits a few seconds first so finished transfers are recorded, not restarted.")
                .font(.caption2)

            if !downloads.notices.isEmpty {
                Text("Notices")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 8)
                ForEach(downloads.notices) { notice in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Formatting.time(notice.date))
                        Text(notice.text)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Button("Cancella avvisi") { downloads.clearNotices() }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
        }
    }

    private func items(in states: Set<DownloadState>) -> [StoredTrack] {
        tracks
            .filter { states.contains($0.downloadState) }
            .sorted {
                // Downloading before queued, then by when they were asked for.
                if $0.downloadState != $1.downloadState {
                    return $0.downloadState == .downloading
                }
                return ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast)
            }
    }
}

/// Prototype `.job`: artwork with the state drawn over it, title and artist, and on
/// the right the percentage, a cancel button or Riprova. Failures read in plain
/// language with their technical details one tap away; every other row shows its
/// technical details on tap.
private struct DownloadRow: View {
    let track: StoredTrack

    @Environment(DownloadManager.self) private var downloads
    @Environment(\.prismaInk) private var ink

    @State private var showingDetails = false
    @State private var addingToPlaylist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    showingDetails.toggle()
                } label: {
                    HStack(spacing: 12) {
                        artwork
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title ?? "Senza titolo")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(ink.primary)
                                .lineLimit(1)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(ink.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(showingDetails ? "Nasconde i dettagli tecnici" : "Mostra i dettagli tecnici")

                trailing
            }

            if let refusal = downloads.refusals[track.serverID] {
                ProblemBlock(error: refusal)
            }

            if track.downloadState == .failed {
                TechnicalDetailsToggle(expanded: $showingDetails)
            }

            if showingDetails {
                VStack(alignment: .leading, spacing: 8) {
                    if track.downloadState == .failed {
                        ErrorReport(storedText: track.errorText ?? "No error text was recorded for this failure.")
                    }
                    TrackTechnicalDetails(track: track)
                }
                .foregroundStyle(ink.primary)
                .padding(.bottom, 12)
            }
        }
        .contextMenu {
            TrackMenuItems(track: track, addingToPlaylist: $addingToPlaylist)
        }
        .swipeActions(edge: .trailing) {
            switch track.downloadState {
            case .queued, .downloading:
                Button("Annulla", role: .destructive) { downloads.cancel(track) }
            case .failed, .cancelled:
                Button("Ignora") { downloads.dismiss(track) }
            case .downloaded:
                Button("Rimuovi", role: .destructive) { downloads.removeFile(track) }
            case .notDownloaded:
                EmptyView()
            }
        }
        .sheet(isPresented: $addingToPlaylist) {
            AddToPlaylistSheet(track: track)
        }
    }

    private var subtitle: String {
        if track.downloadState == .failed, downloads.preflights[track.serverID] == nil {
            return PlainLanguage.summary(for: track.failureCause)
        }
        return track.album?.artist ?? ""
    }

    /// Prototype `.jthumb`: a ring over the artwork while downloading, a clock while
    /// queued.
    private var artwork: some View {
        ZStack {
            CoverArt(album: track.album, side: 44, cornerRadius: 10)
            if downloads.preflights[track.serverID] != nil || track.downloadState == .downloading || track.downloadState == .queued {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 44, height: 44)
                if downloads.preflights[track.serverID] != nil {
                    ProgressRing(fraction: nil, color: .white)
                } else if track.downloadState == .downloading {
                    ProgressRing(fraction: DownloadProgress.fraction(of: track, in: downloads), color: .white)
                } else {
                    Image(systemName: "clock")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .accessibilityLabel("In coda")
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if downloads.preflights[track.serverID] != nil {
            EmptyView()
        } else {
            switch track.downloadState {
            case .downloading:
                if let fraction = DownloadProgress.fraction(of: track, in: downloads) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ink.secondary)
                        .frame(minWidth: 44)
                }
            case .queued:
                iconButton("xmark", label: "Annulla download", color: ink.secondary) {
                    downloads.cancel(track)
                }
            case .failed, .cancelled:
                Button {
                    downloads.download(track)
                } label: {
                    Text("Riprova")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ink.accentText)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            case .downloaded:
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(ink.accent)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Scaricato")
            case .notDownloaded:
                EmptyView()
            }
        }
    }

    private func iconButton(_ systemName: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}
