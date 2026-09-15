import Foundation
import SwiftData
import SwiftUI

/// Words for where an acquisition is. Server and device phases say which they are,
/// so one row reads continuously from the tap in Search to the device download.
enum AcquisitionText {
    /// `pollFailures`: failed polls in a row, so a row waiting on the server says the
    /// server is not answering while the coordinator retries.
    static func phase(of record: PendingAcquisition, pollFailures: Int = 0) -> String {
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
        case .failed:
            return record.failure?.phase ?? "Non riuscito"
        }
    }

    static func serverPercent(of record: PendingAcquisition) -> Int? {
        guard record.stage == .onServer, record.serverJobState == ServerJob.State.running.rawValue,
              let progress = record.serverProgress else { return nil }
        return Int((progress * 100).rounded())
    }
}

/// The state slot of a search result that is not in the library: an arrow to
/// acquire it, the chain's progress while it runs, retry once it failed.
struct AcquisitionStateIcon: View {
    let song: SongResult
    let record: PendingAcquisition?

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(\.prismaInk) private var ink

    var body: some View {
        Group {
            if let record {
                switch record.stage {
                case .failed:
                    Button {
                        acquisitions.retry(videoID: record.videoID)
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
                case .requesting, .syncing, .handingOff:
                    ProgressRing(fraction: nil, color: ink.accent, side: 18)
                        .accessibilityLabel(AcquisitionText.phase(of: record))
                }
            } else {
                Button {
                    acquisitions.acquire(song)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ink.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Scarica sul server e sul telefono")
            }
        }
        .frame(width: 44, height: 44)
    }
}

/// A failed acquisition: what failed and what to check, Riprova and Rimuovi, and
/// nothing else: the message carries the cause.
struct AcquisitionProblem: View {
    let record: PendingAcquisition

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
                link("Riprova") { acquisitions.retry(videoID: record.videoID) }
                link("Rimuovi") { acquisitions.remove(videoID: record.videoID) }
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
    let record: PendingAcquisition

    @Environment(AcquisitionCoordinator.self) private var acquisitions
    @Environment(AppSettings.self) private var settings
    @Environment(\.prismaInk) private var ink
    @State private var artworkError: APIError?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title ?? "Senza titolo")
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
