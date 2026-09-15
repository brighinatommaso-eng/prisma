import Foundation
import SwiftData
import SwiftUI

// MARK: - Plain language

/// The only diagnosis the interface shows: one or two complete sentences saying what
/// failed and what to check. Chosen from typed facts (the error's kind, URLError
/// code and HTTP status, or a track's recorded cause), never from error text.
enum PlainLanguage {
    static func message(for error: APIError) -> String {
        if let message = error.message {
            return message
        }
        switch error.kind {
        case .notConfigured:
            return "Nessun indirizzo del server impostato: inseriscilo in Impostazioni, per esempio http://nome-server:8000."
        case .invalidAddress:
            return "L'indirizzo del server non è valido: correggilo in Impostazioni."
        case .invalidInput:
            return error.title + "."
        case .cancelled:
            return "La richiesta è stata annullata prima di finire: riprova."
        case .transport:
            return transport(error.urlErrorCode)
        case .http:
            return http(error.httpStatus)
        case .invalidResponse, .decoding:
            return "La risposta del server non è leggibile: app e backend potrebbero non essere allineati, quindi aggiorna il backend."
        case .notAnImage:
            return "Il server ha inviato un'immagine non valida al posto della copertina: verrà ritentata alla prossima sincronizzazione."
        case .storage:
            return "Non è stato possibile leggere o salvare dati sul telefono: controlla lo spazio libero e riprova."
        case .verification:
            return "Il file ricevuto non corrisponde a quello del server: riprova il download; se si ripete, il file sul server potrebbe essere danneggiato."
        case .unexpected:
            return "Si è verificato un errore imprevisto: riprova; se si ripete, riavvia l'app."
        }
    }

    /// A transport failure, by URLError code.
    private static func transport(_ code: Int?) -> String {
        switch code {
        case -1009?:
            return "Il telefono non ha una rete utilizzabile: controlla che la modalità aereo sia spenta e, se il server è in rete locale, che Prisma abbia l'accesso alla rete locale in Impostazioni di iOS."
        case -1003?, -1006?:
            return "Il nome del server non è stato trovato: controlla l'indirizzo in Impostazioni e, se usi Tailscale, che sia connesso su questo telefono."
        case -1004?:
            return "Il server non accetta connessioni su quella porta: controlla il numero di porta in Impostazioni e che il backend sia in esecuzione."
        case -1001?:
            return "Il server non ha risposto in tempo: controlla che sia acceso e raggiungibile, con Tailscale connesso e l'indirizzo giusto."
        case -1005?:
            return "La connessione con il server si è interrotta a metà: riprova; se succede ancora, il server potrebbe essere in riavvio."
        case -1020?:
            return "I dati cellulari sono disattivati per Prisma: attivali in Impostazioni di iOS, alla voce Prisma."
        case -1022?:
            return "iOS ha bloccato la connessione HTTP al server: questa versione dell'app non ha l'eccezione necessaria, serve una nuova build."
        case -1200?, -1202?:
            return "La connessione sicura non è riuscita: il server usa HTTP, quindi l'indirizzo deve iniziare con http:// e non con https://."
        case -1011?, -1017?:
            return "All'indirizzo ha risposto qualcosa che non è il server Prisma: controlla che l'indirizzo in Impostazioni punti al backend."
        default:
            return "Impossibile raggiungere il server: controlla l'indirizzo in Impostazioni, che il server sia acceso e che Tailscale sia connesso."
        }
    }

    /// An HTTP error response, by status.
    private static func http(_ status: Int?) -> String {
        switch status {
        case 404?:
            return "Il server non conosce questa richiesta: controlla che l'indirizzo punti al backend Prisma e che il backend sia aggiornato."
        case 410?:
            return "Il server non ha più il file richiesto: sincronizza la libreria per aggiornare il catalogo."
        case 400?, 422?:
            return "Il server ha rifiutato la richiesta come non valida: app e backend potrebbero non essere allineati, quindi aggiorna il backend."
        case 502?, 504?:
            return "Il server non è riuscito a contattare YouTube Music: riprova tra poco; se succede sempre, controlla la connessione a internet del server."
        case let status? where status >= 500:
            return "Il server ha avuto un errore interno: controlla i log del backend, poi riprova."
        default:
            return "Il server ha risposto con un errore inatteso: controlla che l'indirizzo in Impostazioni punti al backend Prisma."
        }
    }

    /// A download on this iPhone that failed, by its recorded cause.
    static func message(for cause: FailureCause?) -> String {
        guard let cause else {
            return "Il download non è riuscito per un errore imprevisto: tocca Riprova; se si ripete, riavvia l'app."
        }
        switch cause {
        case .unreachable:
            return "Il download non è riuscito perché il server non era raggiungibile: controlla l'indirizzo in Impostazioni, che il server sia acceso e che Tailscale sia connesso, poi tocca Riprova."
        case .neverStarted:
            return "iOS non ha mai avviato il trasferimento, di solito perché il server non è raggiungibile: controlla l'indirizzo in Impostazioni, poi tocca Riprova."
        case .noAddress:
            return "Il download non è partito perché manca un indirizzo del server valido: impostalo in Impostazioni, poi tocca Riprova."
        case .httpStatus:
            return "Il server non ha il file di questo brano: sincronizza la libreria; se il brano resta, riscaricalo sul server da Cerca."
        case .verification:
            return "Il file ricevuto era danneggiato e non corrispondeva a quello del server: tocca Riprova per scaricarlo di nuovo."
        case .storage:
            return "Spazio insufficiente o salvataggio non riuscito sul telefono: libera spazio, poi tocca Riprova."
        case .missingServerData:
            return "Il server non ha fornito i dati del file: sincronizza la libreria, poi tocca Riprova."
        case .serverFileChanged:
            return "Il file sul server è cambiato durante il download: tocca Riprova per scaricare la versione nuova."
        case .fileMissing:
            return "Il file di questo brano non è più sul telefono: tocca Riprova per scaricarlo di nuovo."
        case .systemCancelled:
            return "iOS ha interrotto il trasferimento, per esempio perché l'aggiornamento in background è disattivato per Prisma: controllalo in Impostazioni di iOS, poi tocca Riprova."
        case .other:
            return "Il download non è riuscito per un errore imprevisto: tocca Riprova; se si ripete, riavvia l'app."
        }
    }
}

// MARK: - Problem

/// A problem stated in full, in plain language, with a warning icon.
struct ProblemBlock: View {
    let text: String

    @Environment(\.prismaInk) private var ink

    init(_ text: String) {
        self.text = text
    }

    init(error: APIError) {
        text = PlainLanguage.message(for: error)
    }

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ink.favourite)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(ink.primary)
        .padding(.vertical, 6)
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
            ProblemBlock(PlainLanguage.message(for: track.failureCause))
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
