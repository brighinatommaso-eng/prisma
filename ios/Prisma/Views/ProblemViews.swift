import Foundation
import SwiftData
import SwiftUI

// MARK: - Plain language

/// One short sentence for a problem, chosen from its typed cause or kind, never
/// from the error text. The full technical text stays one tap away.
enum PlainLanguage {
    static func summary(for cause: FailureCause?) -> String {
        guard let cause else { return "Download non riuscito" }
        switch cause {
        case .unreachable: return "Impossibile raggiungere il server"
        case .neverStarted: return "Il download non è mai partito"
        case .noAddress: return "Nessun indirizzo del server impostato"
        case .httpStatus: return "Il server non ha questo file"
        case .verification: return "Il file ricevuto era danneggiato"
        case .storage: return "Spazio insufficiente o salvataggio non riuscito"
        case .missingServerData: return "Dati del brano incompleti: sincronizza la libreria"
        case .serverFileChanged: return "Il file sul server è cambiato durante il download"
        case .fileMissing: return "Il file scaricato non è più sul telefono"
        case .systemCancelled: return "iOS ha interrotto il download"
        case .other: return "Download non riuscito"
        }
    }

    static func summary(for error: APIError) -> String {
        switch error.kind {
        case .notConfigured: return "Nessun indirizzo del server impostato"
        case .invalidAddress: return "Indirizzo del server non valido"
        case .invalidInput: return error.title
        case .cancelled: return "Richiesta annullata"
        case .transport: return "Impossibile raggiungere il server"
        case .http: return "Il server ha risposto con un errore"
        case .invalidResponse, .decoding: return "Risposta del server non leggibile"
        case .notAnImage: return "Immagine non valida"
        case .storage: return "Salvataggio sul telefono non riuscito"
        case .verification: return "File danneggiato"
        case .unexpected: return "Errore imprevisto"
        }
    }
}

// MARK: - Problem with demoted details

/// A problem stated in plain language, with "Mostra dettagli tecnici" revealing the
/// full `ErrorReport` (text, codes, URL and the copy button) unchanged.
struct ProblemBlock: View {
    enum Details {
        case error(APIError)
        case stored(String)
    }

    let summary: String
    let details: Details

    @Environment(\.prismaInk) private var ink
    @State private var expanded = false

    init(summary: String, details: Details) {
        self.summary = summary
        self.details = details
    }

    init(error: APIError) {
        summary = PlainLanguage.summary(for: error)
        details = .error(error)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ink.favourite)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(ink.primary)
            .padding(.top, 6)

            TechnicalDetailsToggle(expanded: $expanded)

            if expanded {
                Group {
                    switch details {
                    case .error(let error):
                        ErrorReport(error: error)
                    case .stored(let text):
                        ErrorReport(storedText: text)
                    }
                }
                .foregroundStyle(ink.primary)
                .padding(.bottom, 8)
            }
        }
    }
}

/// "Mostra dettagli tecnici" / "Nascondi dettagli tecnici", 44 pt tall.
struct TechnicalDetailsToggle: View {
    @Binding var expanded: Bool

    @Environment(\.prismaInk) private var ink

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(expanded ? "Nascondi dettagli tecnici" : "Mostra dettagli tecnici")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(ink.secondary)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

/// A block of developer information behind "Mostra dettagli tecnici".
struct TechnicalDetailsSection<Content: View>: View {
    let content: Content

    @Environment(\.prismaInk) private var ink
    @State private var expanded = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TechnicalDetailsToggle(expanded: $expanded)
            if expanded {
                content
                    .font(.caption)
                    .foregroundStyle(ink.primary)
                    .padding(.bottom, 12)
            }
        }
    }
}

// MARK: - Download state as an icon

/// Prototype `.state`: equaliser for the playing track, an accent check when
/// downloaded, a dimmed arrow when not, a ring while downloading. No words; the
/// accessibility label says the state.
struct DownloadStateIcon: View {
    let track: StoredTrack

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlaybackEngine.self) private var playback
    @Environment(\.prismaInk) private var ink

    var body: some View {
        content
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        if playback.currentTrackID == track.serverID {
            EqualizerBars(isAnimating: playback.isPlaying)
        } else if downloads.preflights[track.serverID] != nil {
            ProgressRing(fraction: nil, color: ink.accent, side: 18)
                .accessibilityLabel("Verifica del server in corso")
        } else {
            switch track.downloadState {
            case .downloaded:
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(ink.accent)
                    .accessibilityLabel("Scaricato")
            case .downloading:
                ProgressRing(fraction: DownloadProgress.fraction(of: track, in: downloads), color: ink.accent, side: 18)
            case .queued:
                Image(systemName: "clock")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ink.secondary)
                    .accessibilityLabel("In coda")
            case .notDownloaded, .cancelled:
                Button {
                    downloads.download(track)
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ink.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Scarica")
            case .failed:
                Button {
                    downloads.download(track)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink.favourite)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download non riuscito. Riprova")
            }
        }
    }
}

enum DownloadProgress {
    /// 0...1 once iOS has reported the expected size, nil before.
    static func fraction(of track: StoredTrack, in downloads: DownloadManager) -> Double? {
        guard let token = track.downloadToken, let progress = downloads.progress[token], progress.expected > 0 else {
            return nil
        }
        return min(1, Double(progress.received) / Double(progress.expected))
    }
}

// MARK: - Track row

/// The prototype's `.trk`: leading number or artwork, title and subtitle, duration,
/// and the state icon. Transparent; the problem, when there is one, sits under it in
/// plain language.
///
/// Tapping plays a downloaded track, or starts the download of one that is not.
/// Favourite, add to playlist and every download action are in the long-press menu,
/// and favourite is also a leading swipe.
struct TrackRow<Leading: View>: View {
    let track: StoredTrack
    let subtitle: String?
    /// Problems from outside the track, e.g. artwork that failed to load.
    let extraProblem: APIError?
    let onPlay: () -> Void
    let leading: Leading

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlaylistStore.self) private var store
    @Environment(\.prismaInk) private var ink
    @State private var addingToPlaylist = false

    init(
        track: StoredTrack,
        subtitle: String? = nil,
        extraProblem: APIError? = nil,
        onPlay: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.track = track
        self.subtitle = subtitle
        self.extraProblem = extraProblem
        self.onPlay = onPlay
        self.leading = leading()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button(action: primaryAction) {
                    HStack(spacing: 13) {
                        leading
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title ?? "Senza titolo")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(ink.primary)
                                .lineLimit(1)
                            if let subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(ink.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(Formatting.trackTime(track.durationS))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(ink.secondary)
                    }
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                DownloadStateIcon(track: track)
                    .padding(.trailing, -10)
            }

            TrackProblems(track: track, extraProblem: extraProblem)
        }
        .contextMenu {
            TrackMenuItems(track: track, addingToPlaylist: $addingToPlaylist)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.toggleFavourite(track)
            } label: {
                Label(track.isFavourite ? "Rimuovi dai preferiti" : "Preferito",
                      systemImage: track.isFavourite ? "heart.slash" : "heart")
            }
            .tint(.pink)
        }
        .sheet(isPresented: $addingToPlaylist) {
            AddToPlaylistSheet(track: track)
        }
    }

    private func primaryAction() {
        switch track.downloadState {
        case .downloaded:
            onPlay()
        case .notDownloaded, .cancelled, .failed:
            if downloads.preflights[track.serverID] == nil {
                downloads.download(track)
            }
        case .queued, .downloading:
            break
        }
    }
}

/// A track's current problems: a refused download, a failed one, and anything the
/// row itself adds.
struct TrackProblems: View {
    let track: StoredTrack
    var extraProblem: APIError?

    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        if let refusal = downloads.refusals[track.serverID] {
            ProblemBlock(error: refusal)
        }
        if track.downloadState == .failed, downloads.preflights[track.serverID] == nil {
            ProblemBlock(
                summary: PlainLanguage.summary(for: track.failureCause),
                details: .stored(track.errorText ?? "No error text was recorded for this failure.")
            )
        }
        if let extraProblem {
            ProblemBlock(error: extraProblem)
        }
    }
}

/// The long-press menu of a track: favourite, add to playlist, and the download
/// actions that fit its state.
struct TrackMenuItems: View {
    let track: StoredTrack
    @Binding var addingToPlaylist: Bool

    @Environment(DownloadManager.self) private var downloads
    @Environment(PlaylistStore.self) private var store

    var body: some View {
        Button {
            store.toggleFavourite(track)
        } label: {
            Label(track.isFavourite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                  systemImage: track.isFavourite ? "heart.slash" : "heart")
        }
        Button {
            addingToPlaylist = true
        } label: {
            Label("Aggiungi a playlist…", systemImage: "text.badge.plus")
        }
        switch track.downloadState {
        case .notDownloaded:
            Button {
                downloads.download(track)
            } label: {
                Label("Scarica", systemImage: "arrow.down.to.line")
            }
        case .queued, .downloading:
            Button(role: .destructive) {
                downloads.cancel(track)
            } label: {
                Label("Annulla download", systemImage: "xmark")
            }
        case .downloaded:
            Button(role: .destructive) {
                downloads.removeFile(track)
            } label: {
                Label("Rimuovi dal dispositivo", systemImage: "trash")
            }
        case .failed, .cancelled:
            Button {
                downloads.download(track)
            } label: {
                Label("Riprova", systemImage: "arrow.clockwise")
            }
            Button {
                downloads.dismiss(track)
            } label: {
                Label("Ignora", systemImage: "xmark.circle")
            }
        }
    }
}
