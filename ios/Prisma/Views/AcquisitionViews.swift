import Foundation
import SwiftData
import SwiftUI

/// Words for where an acquisition is. Server and device phases say which they are,
/// so one row reads continuously from the tap in Search to the device download.
enum AcquisitionText {
    /// `pollFailures`: failed polls in a row, so a row waiting on the server says the
    /// server is not answering while the coordinator retries.
    static func phase(of record: AcquisitionData, pollFailures: Int = 0) -> String {
        switch record.stage {
        case .requesting:
            return "Sul server · invio della richiesta…"
        case .onServer where pollFailures > 0:
            return "Sul server · il server non risponde, nuovo tentativo…"
        case .onServer:
            switch record.serverJobState.flatMap({ ServerJob.State(rawValue: $0) }) {
            case .queued: return "Sul server · in coda"
            case .running: return "Sul server · download da YouTube"
            default: return "Sul server"
            }
        case .syncing:
            return "Libreria · sincronizzazione…"
        case .handingOff:
            return "Sul telefono · avvio del download…"
        case .deletingFromServer:
            return "Sul telefono · rimozione della copia sul server…"
        case .failed:
            return record.failurePhase ?? "Non riuscito"
        }
    }

    static func serverPercent(of record: AcquisitionData) -> Int? {
        guard record.stage == .onServer, record.serverJobState == ServerJob.State.running.rawValue,
              let progress = record.serverProgress else { return nil }
        return Int((progress * 100).rounded())
    }
}

/// The state slot of a search result that is not in the library: an arrow to
/// acquire it, the chain's progress while it runs, retry once it failed.
struct AcquisitionStateIcon: View {
    let record: AcquisitionData?
    /// Opens the destination choice. The row owns the sheet, because the sheet
    /// outlives this slot and must not be torn down by a redraw of it.
    let onDownload: () -> Void

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(\.prismaInk) private var ink

    var body: some View {
        Group {
            if let record {
                switch record.stage {
                case .failed:
                    Button {
                        acquisitions.retry(videoID: record.id)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(ink.favourite)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Acquisizione non riuscita. Riprova")
                case .onServer where record.serverJobState == ServerJob.State.queued.rawValue:
                    Image(systemName: "clock")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ink.secondary)
                        .accessibilityLabel("In coda sul server")
                case .onServer:
                    ProgressRing(fraction: record.serverProgress, color: ink.accent, side: 18)
                        .accessibilityLabel(AcquisitionText.phase(of: record))
                case .requesting, .syncing, .handingOff, .deletingFromServer:
                    ProgressRing(fraction: nil, color: ink.accent, side: 18)
                        .accessibilityLabel(AcquisitionText.phase(of: record))
                }
            } else {
                Button(action: onDownload) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ink.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Scarica: scegli dove tenerlo")
            }
        }
        .frame(width: 44, height: 44)
    }
}

/// A failed acquisition: what failed and what to check, Riprova and Rimuovi, and
/// nothing else: the message carries the cause.
struct AcquisitionProblem: View {
    let record: AcquisitionData

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(\.prismaInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text(record.failureMessage ?? "L'acquisizione non è riuscita per un errore imprevisto: tocca Riprova; se si ripete, riavvia l'app.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ink.favourite)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(ink.primary)
            .padding(.top, 6)

            HStack(spacing: 20) {
                link("Riprova") { acquisitions.retry(videoID: record.id) }
                link("Rimuovi") { acquisitions.remove(videoID: record.id) }
                Spacer(minLength: 0)
            }
        }
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ink.accentText)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

/// Errors from the coordinator itself, e.g. the store could not be written.
struct AcquisitionCoordinatorError: View {
    @Environment(AcquisitionCoordinator.self) private var acquisitions

    var body: some View {
        if let error = acquisitions.lastError {
            VStack(alignment: .leading, spacing: 0) {
                ProblemBlock(error: error)
                DismissLink { acquisitions.clearError() }
            }
        }
    }
}

/// The Downloads row of a track still in the server phase, or failed before it
/// reached the library. Same layout as a device download row.
struct AcquisitionRow: View {
    let record: AcquisitionData

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(AppSettings.self) private var settings
    @Environment(\.prismaInk) private var ink
    @State private var artworkError: APIError?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                    Text(AcquisitionText.phase(of: record, pollFailures: acquisitions.pollFailures))
                        .font(.caption)
                        .foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let percent = AcquisitionText.serverPercent(of: record) {
                    Text("\(percent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(ink.secondary)
                        .frame(minWidth: 44)
                }
            }
            .frame(minHeight: 62)
            .accessibilityElement(children: .combine)

            if record.stage == .failed {
                AcquisitionProblem(record: record)
            }
        }
    }

    /// The search artwork with the server phase drawn over it.
    private var artwork: some View {
        ZStack {
            if let client = artworkClient {
                RemoteImage(client: client, reference: record.artworkURL, side: 44, failure: $artworkError)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                CoverPlaceholder(palette: nil, side: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if record.stage != .failed {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 44, height: 44)
                if record.stage == .onServer, record.serverJobState == ServerJob.State.queued.rawValue {
                    Image(systemName: "clock")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.white.opacity(0.85))
                } else if record.stage == .onServer {
                    ProgressRing(fraction: record.serverProgress, color: .white)
                } else {
                    ProgressRing(fraction: nil, color: .white)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Artwork only; without a usable address the row shows a placeholder, and the
    /// acquisition itself reports the address problem.
    private var artworkClient: APIClient? {
        do {
            return try settings.makeClient()
        } catch {
            return nil
        }
    }
}

// MARK: - Where to keep it

/// The choice made before anything is fetched: Telefono, Server or Entrambi.
///
/// Opened from the download button in Cerca and from a Preferiti row that is not on
/// the phone, and told apart by `reason`: from Preferiti it also says why the track
/// will not play, which is the answer to the tap that opened it.
///
/// Holds an `AcquisitionRequest` and a string, both values. The sheet stays up on
/// its own while the library changes underneath it, and the coordinator reads the
/// store back when a destination is tapped.
///
/// Opened from Cerca presented over a playlist, it carries `joining` too: the
/// playlist the track goes into when a destination is chosen, by id. The slot is
/// written first and the acquisition started second, both at the tap, so the track
/// is in the playlist even if the download then fails — as it is in Preferiti.
struct DestinationSheet: View {
    let request: AcquisitionRequest
    /// Why the track cannot be played right now, or nil when nothing was expected
    /// to play yet.
    let reason: String?
    /// The playlist the track also joins, or nil.
    var joining: PlaylistSlotTarget? = nil

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(PlaylistStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.title ?? "Senza titolo")
                            .font(.headline)
                        if let line = subtitle {
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let reason {
                            Text(reason)
                                .font(.footnote)
                                .padding(.top, 6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    ForEach(AcquisitionDestination.allCases) { destination in
                        Button {
                            join()
                            acquisitions.acquire(request, destination: destination)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: destination.symbol)
                                    .font(.system(size: 17))
                                    .frame(width: 26)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(destination.label)
                                        .font(.subheadline.weight(.semibold))
                                    Text(destination.explanation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(minHeight: 50)
                            .contentShape(Rectangle())
                        }
                    }
                } header: {
                    Text("Dove tenerlo").textCase(nil)
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Scarica")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var subtitle: String? {
        let line = [request.artist, request.albumName].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    private var footer: String {
        guard let joining else {
            return "Il brano viene aggiunto ai preferiti in ogni caso, anche se il download non riesce."
        }
        if joining.holdsTrack {
            return "Il brano è già in “\(joining.playlistName)”, quindi non viene aggiunto di nuovo. Finisce nei preferiti in ogni caso, anche se il download non riesce."
        }
        return "Il brano entra in “\(joining.playlistName)” e nei preferiti in ogni caso, anche se il download non riesce."
    }

    /// Puts the track in the playlist it was chosen for, resolved at the tap. A
    /// playlist that already holds it is left alone: the choice here is about
    /// downloading, and a second copy is never added from a picker.
    private func join() {
        guard let joining, !joining.holdsTrack,
              let playlist = ModelLookup.playlist(joining.playlistID, in: context) else { return }
        store.add([request.draft], to: playlist)
    }
}
