import Foundation
import SwiftData
import SwiftUI

/// The download queue, rendered from the local store. No network call.
///
/// One list from the tap in Search to a playable track: acquisitions still in the
/// server phase come first in "In corso", followed by device downloads, and each
/// row says which phase it is in. Above them, one line per imported playlist whose
/// tracks are still arriving.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(DemusImporter.self) private var importer
    @Query(sort: \PendingAcquisition.createdAt) private var acquisitions: [PendingAcquisition]
    @Environment(\.prismaInk) private var ink

    @Query private var tracks: [StoredTrack]
    @Query private var favourites: [FavouriteTrack]
    @Query(sort: \PlaylistImport.startedAt) private var imports: [PlaylistImport]

    var body: some View {
        // The one place this screen reads the store.
        let data = Projection.downloads(
            tracks: tracks, acquisitions: acquisitions, favourites: favourites, imports: imports
        )
        // A device download the server's absence stopped is started again when the
        // server is back, so it belongs with what is on its way, not with what failed.
        let inProgress = data.tracks(in: [.downloading, .queued]) + data.tracks(in: [.failed]).filter(\.isWaitingForServer)
        let failed = data.tracks(in: [.failed]).filter { !$0.isWaitingForServer }
        let cancelled = data.tracks(in: [.cancelled])
        let downloaded = data.tracks(in: [.downloaded])
        let acquiring = data.acquisitions.filter(\.isActive)
        let acquisitionsFailed = data.acquisitions.filter { !$0.isActive }

        List {
            AcquisitionCoordinatorError()
                .prismaRow()
                .listRowSeparator(.hidden)

            ForEach(data.imports) { line in
                ImportProgressLine(data: line)
                    .prismaRow()
            }

            if data.isEmpty {
                Text("Nessun download. Tocca un brano in Cerca, o la freccia accanto a un brano in Libreria.")
                    .font(.subheadline)
                    .foregroundStyle(ink.secondary)
                    .padding(.vertical, 16)
                    .prismaRow()
                    .listRowSeparator(.hidden)
            }

            group("In corso", inProgress, acquisitions: acquiring)
            group("Non riuscito", failed, acquisitions: acquisitionsFailed)
            group("Annullati", cancelled)
            group("Scaricati", downloaded)

            transferFooter
                .padding(.top, 12)
                .prismaRow()
                .listRowSeparator(.hidden)
        }
        .prismaList()
        .navigationTitle("Download")
        // An import whose every track is on the phone has no line left to show; its
        // record is forgotten the moment the projection sees that. By id, like every
        // action: the projection's values, never the records themselves.
        .task(id: data.completedImportIDs) {
            importer.forget(data.completedImportIDs)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ matching: [TrackRowData], acquisitions: [AcquisitionData] = []) -> some View {
        if !matching.isEmpty || !acquisitions.isEmpty {
            SectionLabel(title)
                .prismaRow()
                .listRowSeparator(.hidden, edges: .top)
            ForEach(acquisitions) { record in
                AcquisitionRow(record: record)
                    .prismaRow()
            }
            ForEach(matching) { track in
                DownloadRow(data: track)
                    .prismaRow()
            }
        }
    }

    /// What the download machinery did on its own, e.g. transfers restarted after
    /// the app was closed, and the manual transfer check.
    @ViewBuilder
    private var transferFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !downloads.notices.isEmpty {
                SectionLabel("Avvisi")
                ForEach(downloads.notices) { notice in
                    Text(notice.date.formatted(date: .omitted, time: .shortened) + " · " + notice.text)
                        .font(.footnote)
                        .foregroundStyle(ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DismissLink { downloads.clearNotices() }
            }
            Button {
                downloads.checkTransfers(reason: "controllo manuale")
            } label: {
                HStack(spacing: 8) {
                    if downloads.isChecking {
                        ProgressView()
                            .tint(ink.secondary)
                    }
                    Text(downloads.isChecking ? "Controllo dei trasferimenti…" : "Controlla i trasferimenti")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ink.accentText)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(downloads.isChecking)
            Text("Riavvia i download che iOS ha perso, per esempio dopo aver chiuso l'app dal selettore delle app. Succede anche da solo a ogni apertura.")
                .font(.caption)
                .foregroundStyle(ink.secondary)
        }
        .padding(.bottom, 12)
    }

}

/// Prototype `.job`: artwork with the state drawn over it, title and artist, and on
/// the right the percentage, a cancel button or Riprova. The shared track row, so
/// tap, long press, swipes and problems are the same as on every other screen.
private struct DownloadRow: View {
    let data: TrackRowData

    @Environment(DownloadManager.self) private var downloads
    @Environment(\.modelContext) private var context
    @Environment(\.prismaInk) private var ink

    var body: some View {
        TrackRow(data: data, subtitle: subtitle, subtitleLineLimit: 2, showsDuration: false) {
            // 44 pt artwork in the job row's 62 pt height.
            artwork
                .padding(.vertical, 9)
        } trailing: {
            trailing
        }
    }

    /// Device-phase rows say so, to read apart from acquisitions still on the server.
    private var subtitle: String {
        if data.isWaitingForServer, downloads.preflights[data.id] == nil {
            return "In attesa · server non raggiungibile"
        }
        if data.downloadState == .failed, downloads.preflights[data.id] == nil {
            return "Download sul telefono non riuscito"
        }
        switch data.downloadState {
        case .queued, .downloading:
            return ["Sul telefono", data.artist].compactMap { $0 }.joined(separator: " · ")
        default:
            return data.artist ?? ""
        }
    }

    /// Prototype `.jthumb`: a ring over the artwork while downloading, a clock while
    /// queued.
    private var artwork: some View {
        ZStack {
            CoverArt(cover: data.cover, side: 44, cornerRadius: 10)
            if downloads.preflights[data.id] != nil || data.downloadState == .downloading || data.downloadState == .queued {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 44, height: 44)
                if downloads.preflights[data.id] != nil {
                    ProgressRing(fraction: nil, color: .white)
                } else if data.downloadState == .downloading {
                    ProgressRing(fraction: DownloadProgress.fraction(of: data, in: downloads), color: .white)
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
        if downloads.preflights[data.id] != nil {
            EmptyView()
        } else {
            switch data.downloadState {
            case .downloading:
                if let fraction = DownloadProgress.fraction(of: data, in: downloads) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ink.secondary)
                        .frame(minWidth: 44)
                }
            case .queued:
                iconButton("xmark", label: "Annulla download", color: ink.secondary) {
                    guard let track = ModelLookup.track(data.id, in: context) else { return }
                    downloads.cancel(track)
                }
            case .failed, .cancelled:
                Button {
                    guard let track = ModelLookup.track(data.id, in: context) else { return }
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
