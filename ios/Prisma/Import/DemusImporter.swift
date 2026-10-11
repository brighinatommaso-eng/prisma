import Foundation
import Observation
import SwiftData

/// How much room on this phone the tracks of an import are expected to take.
///
/// An import knows durations, not file sizes: the files do not exist yet. The
/// server stores what YouTube already serves as AAC in M4A, about 128 kbit/s, and
/// only when a video has no such track does it encode one itself at 192 kbit/s
/// (spec 3.2, `backend/app/downloader.py`). The estimate takes the higher rate for
/// every track, which is half as much again as the usual case, and adds a fixed
/// amount per file for the container and the cover embedded in its tags. It is
/// meant to err on the side of saying "not enough" a little early, because the
/// alternative is fifty downloads that start and then fail one by one.
nonisolated enum DemusEstimate {
    /// 192 kbit/s, the highest rate the server stores.
    static let bytesPerSecond = 192_000 / 8
    /// For a song the export gave no duration for.
    static let assumedDurationS = 240
    /// Container, tags and the embedded cover.
    static let overheadPerTrack = 256 * 1024

    static func bytes(durations: [Int?]) -> Int64 {
        durations.reduce(Int64(0)) { total, duration in
            total + Int64((duration ?? assumedDurationS) * bytesPerSecond + overheadPerTrack)
        }
    }
}

/// Reads a file another app handed over, or the user picked, into memory.
///
/// Such a URL is only good for a moment. One from the file picker is
/// security-scoped: it can be read between `startAccessing…` and `stopAccessing…`
/// and at no other time. One opened from a share sheet is a copy iOS made in this
/// app's `Documents/Inbox`, because the app declares that it does not open
/// documents in place; nothing else will ever remove that copy, so it is deleted
/// here once its bytes have been read, or could not be. Either way the bytes are
/// taken at once and the URL is not kept.
nonisolated enum IncomingFile {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
            removeInboxCopy(url)
        }

        // Asked before reading, so a file that could never be accepted is not
        // loaded into memory first. Not every provider reports a size; then the
        // bytes themselves are counted below.
        let reported: Int?
        do {
            reported = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } catch {
            reported = nil
        }
        if let reported, reported > limit {
            throw tooLarge(reported, limit: limit)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw APIError.storage(
                "Could not read the file to import", location: nil, error: error,
                message: "Impossibile leggere il file scelto, quindi non è stato importato nulla: riprova; se il file è su iCloud Drive, aspetta che sia scaricato sul telefono."
            )
        }
        guard data.count <= limit else {
            throw tooLarge(data.count, limit: limit)
        }
        guard !data.isEmpty else {
            throw APIError.invalidInput(
                "Il file è vuoto",
                detail: "Non contiene nessuna playlist: esportala di nuovo da Demus e riprova."
            )
        }
        return data
    }

    private static func tooLarge(_ bytes: Int, limit: Int) -> APIError {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let most = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
        return APIError.invalidInput(
            "Il file è troppo grande per essere una playlist di Demus",
            detail: "Pesa \(size) e il server ne accetta al massimo \(most), quindi non è stato inviato: controlla di aver scelto il file che finisce in .playlist."
        )
    }

    /// Only a file in a folder called Inbox inside this app's own container: that is
    /// where iOS puts the copy it makes, and nowhere else is this app's to tidy.
    private static func removeInboxCopy(_ url: URL) {
        guard url.isFileURL, url.deletingLastPathComponent().lastPathComponent == "Inbox" else { return }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .resolvingSymlinksInPath().path(percentEncoded: false)
        let file = url.resolvingSymlinksInPath().path(percentEncoded: false)
        guard file.hasPrefix(home) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // The bytes are already in memory, or could not be read at all; a copy
            // left behind costs a few kilobytes and is replaced by the next import.
        }
    }
}

/// Importing a playlist exported by the Demus app: from the file to a playlist, its
/// favourites and their downloads.
///
/// Two halves, with the user's confirmation between them.
///
/// Before it, nothing changes anywhere. The file is read into memory, the server
/// parses it (`POST /import/demus`, which only reads), and what came back is held
/// here as plain values for the preview sheet to describe.
///
/// After it, everything is written on this phone first and at once, with no network
/// in the way: the playlist, then the favourites, then one acquisition per track
/// through `AcquisitionCoordinator` — the same chain a single tap in Cerca starts,
/// with destination Entrambi. The server's copy of the collection follows by
/// itself, through the hook `PlaylistStore` already calls. Nothing here starts
/// playback, and nothing here downloads anything: the chain does.
///
/// Created once by `AppModel`. The sheet is presented by `RootView`, so a file
/// opened from another app is answered whichever tab is showing.
@Observable
final class DemusImporter {
    /// A parsed file waiting for the user's answer.
    struct Pending {
        let fileName: String
        let playlist: DemusPlaylist
        /// Free space on this phone when the file was parsed, or nil if iOS would
        /// not say. Read then, so the preview compares against what was true before
        /// anything started.
        let availableBytes: Int64?
    }

    enum Phase {
        case idle
        /// The server is reading the file.
        case parsing(fileName: String)
        case preview(Pending)
        /// With `message` always set, in Italian.
        case failed(APIError)
    }

    /// What to do about the playlist, decided in the preview.
    enum PlaylistChoice: Equatable {
        case createNew
        /// Append to this one only the tracks it does not hold yet.
        case update(UUID)
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let playlists: PlaylistStore
    @ObservationIgnored private let acquisitions: AcquisitionCoordinator
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private var parsing: Task<Void, Never>?
    /// Bumped whenever a file is opened or the sheet is closed, so the answer to a
    /// request that has been superseded is recognised and dropped.
    @ObservationIgnored private var generation = 0

    init(
        context: ModelContext,
        settings: AppSettings,
        playlists: PlaylistStore,
        acquisitions: AcquisitionCoordinator,
        downloads: DownloadManager
    ) {
        self.context = context
        self.settings = settings
        self.playlists = playlists
        self.acquisitions = acquisitions
        self.downloads = downloads
    }

    /// Whether the sheet is up.
    var isActive: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// The parsed file the preview describes, when there is one.
    var pending: Pending? {
        if case .preview(let pending) = phase { return pending }
        return nil
    }

    // MARK: - Before the confirmation

    /// A `.playlist` file arrived: opened from another app, or picked in Libreria.
    ///
    /// Its bytes are taken now, while the URL is still readable, and the URL is not
    /// kept. A file opened while another is being previewed replaces it: nothing
    /// had been changed for the first.
    func open(_ url: URL) {
        generation += 1
        let pass = generation
        parsing?.cancel()
        parsing = nil

        let fileName = url.lastPathComponent
        let file: Data
        let client: APIClient
        do {
            file = try IncomingFile.read(url, limit: APIClient.demusFileLimit)
            client = try settings.makeClient()
        } catch {
            phase = .failed(Self.explained(.from(error)))
            return
        }

        phase = .parsing(fileName: fileName)
        parsing = Task { [weak self] in
            let outcome: Result<DemusPlaylist, APIError>
            do {
                outcome = .success(try await client.importDemus(file: file).value)
            } catch {
                outcome = .failure(.from(error))
            }
            guard let self, self.generation == pass else { return }
            self.parsing = nil
            switch outcome {
            case .success(let playlist):
                self.phase = .preview(Pending(
                    fileName: fileName,
                    playlist: playlist,
                    availableBytes: Self.availableBytes()
                ))
            case .failure(let error):
                self.phase = .failed(Self.explained(error))
            }
        }
    }

    /// The file picker reported a failure instead of a file.
    func pickFailed(_ error: Error) {
        // Closing the picker without choosing is not a failure.
        if let cocoa = error as? CocoaError, cocoa.code == .userCancelled { return }
        generation += 1
        parsing?.cancel()
        parsing = nil
        phase = .failed(APIError.storage(
            "The file picker could not hand over the file", location: nil, error: error,
            message: "Il file scelto non si è potuto aprire, quindi non è stato importato nulla: riprova."
        ))
    }

    /// Annulla, Chiudi, or the sheet swiped away. Nothing was written, so there is
    /// nothing to undo.
    func cancel() {
        generation += 1
        parsing?.cancel()
        parsing = nil
        phase = .idle
    }

    // MARK: - The confirmation

    /// Imports the file the preview is showing.
    ///
    /// In this order, and all of it before this returns:
    ///
    /// 1. The playlist: a new one with the file's name, or the existing one the
    ///    user chose to update.
    /// 2. The favourites: every track of the file, with its duration and the rest
    ///    of what Demus knew. One already in Preferiti is filled in, never
    ///    duplicated, so importing the same file twice adds nothing the second
    ///    time. They are created here, before the slots, so that their order in
    ///    Preferiti is the playlist's (`PlaylistStore.addFavourites`).
    ///    Then the slots: `PlaylistStore.appendMissing(_:to:)` gives the playlist
    ///    one slot per line of the file, in the file's order and repeats included,
    ///    less what it already holds.
    /// 3. The acquisitions, in the file's order, by
    ///    `AcquisitionCoordinator.acquire(_:destination:)`: what is left to fetch
    ///    for each track, which is nothing for one already on the phone and only
    ///    the device download for one already on the server. One save for all.
    /// 4. The record the Downloads tab counts progress from, if anything is left
    ///    to arrive.
    ///
    /// A song the file lists twice is two slots of the playlist, and one favourite
    /// and one acquisition: the playlist is a copy of the list, while a track is
    /// kept and downloaded once however often it is listed. The progress record
    /// holds the distinct tracks, so its total is the number of tracks to arrive,
    /// not the length of the playlist. No request is made here: the acquisition
    /// loop makes them, in the background, as it does today.
    func confirm(_ choice: PlaylistChoice) {
        guard case .preview(let pending) = phase else { return }
        let name = Self.playlistName(pending.playlist.name)
        var seen = Set<String>()
        let songs = pending.playlist.songs.filter { seen.insert($0.videoID).inserted }
        guard !songs.isEmpty else { return }

        var target: Playlist?
        if case .update(let id) = choice {
            // Read back now: the sheet may have been open for a while. If the
            // playlist has been deleted meanwhile, the import makes its own.
            target = ModelLookup.playlist(id, in: context)
        }
        if target == nil {
            target = playlists.createPlaylist(named: name)
        }
        guard let playlist = target else {
            phase = .failed(playlists.lastError ?? APIError.invalidInput(
                "Impossibile creare la playlist",
                detail: "Non è stato importato nulla: riprova."
            ))
            return
        }
        let requests = songs.map { Self.request(for: $0) }
        playlists.addFavourites(requests.map(\.draft))
        // Every line of the file, not the distinct tracks: the playlist keeps repeats.
        playlists.appendMissing(pending.playlist.songs.map { Self.request(for: $0).draft }, to: playlist)

        acquisitions.acquire(requests, destination: .both)

        let ids = songs.map(\.videoID)
        let onPhone = ModelLookup.tracks(ids, in: context).filter { $0.downloadState == .downloaded }.count
        if onPhone < ids.count {
            context.insert(PlaylistImport(name: name, videoIDs: ids))
            do {
                try context.save()
            } catch {
                downloads.notice("L'importazione di “\(name)” è partita, ma la sua riga di avanzamento non si è potuta salvare: i brani si scaricano lo stesso e ciascuno ha la sua riga qui sotto.")
            }
        }

        generation += 1
        phase = .idle
    }

    // MARK: - Progress lines

    /// Forgets imports that have nothing left to say: every track arrived, or the
    /// user closed the line of one that ended with tracks missing. The tracks, the
    /// playlist and the favourites are not touched.
    func forget(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        do {
            let records = try context.fetch(FetchDescriptor<PlaylistImport>()).filter { wanted.contains($0.id) }
            guard !records.isEmpty else { return }
            for record in records {
                context.delete(record)
            }
            try context.save()
        } catch {
            downloads.notice("Impossibile togliere la riga di un'importazione finita: riprova; se si ripete, riavvia l'app.")
        }
    }

    // MARK: - Helpers

    /// The name the playlist gets: the file's, or a stand-in when it has none,
    /// because a playlist cannot be created without one.
    static func playlistName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Playlist da Demus" : name
    }

    /// One song as the acquisition chain takes it, and through its `draft` as
    /// Preferiti does.
    private static func request(for song: DemusSong) -> AcquisitionRequest {
        AcquisitionRequest(
            videoID: song.videoID,
            title: song.title,
            artist: song.artist,
            albumName: song.album,
            durationS: song.durationS,
            artworkURL: song.artworkURL
        )
    }

    private static func availableBytes() -> Int64? {
        do {
            return try LocalFiles.availableCapacity()
        } catch {
            return nil
        }
    }

    /// The same error with a sentence that says what is wrong with the file.
    private static func explained(_ error: APIError) -> APIError {
        var explained = error
        explained.message = message(for: error)
        return explained
    }

    /// What went wrong, for someone holding a file.
    ///
    /// The server answers an unreadable file with 422 and a `detail` written to be
    /// shown. The ones it is known to send are recognised and said in Italian; any
    /// other is passed on in the server's own words after a sentence that says what
    /// it is about, so nothing the server said is lost.
    static func message(for error: APIError) -> String {
        if error.httpStatus == 422 {
            let detail = error.serverDetail ?? ""
            let text = detail.lowercased()
            if text.contains("not an xz file") {
                return "Questo file non è una playlist esportata da Demus: non è nel formato che Demus usa per le sue esportazioni. Esporta di nuovo la playlist da Demus e scegli il file che finisce in .playlist."
            }
            if text.contains("truncated") {
                return "Il file è incompleto: finisce prima della fine dei suoi dati, come succede quando un trasferimento si interrompe. Esportalo di nuovo da Demus e riprova."
            }
            if text.contains("body is empty") {
                return "Il file è vuoto, quindi non c'è nessuna playlist da leggere: esportala di nuovo da Demus."
            }
            if text.contains("limit on the compressed size") {
                return "Il file è troppo grande: il server accetta playlist fino a 4 MB e questa li supera. Controlla di aver scelto il file che finisce in .playlist."
            }
            if text.contains("limit on the decompressed size") {
                return "Il file contiene più dati di quanti il server ne accetti per una playlist, 16 MB una volta decompresso, quindi non è stato letto. Controlla di aver scelto il file che finisce in .playlist."
            }
            let lead = "Il server non è riuscito a leggere questo file come playlist di Demus, quindi non è stato importato nulla."
            return detail.isEmpty ? lead : lead + " Il server dice: “\(detail)”"
        }
        if error.httpStatus == 404 {
            return "Il server non conosce ancora l'importazione da Demus, quindi il file non è stato letto: aggiorna il backend, poi riprova."
        }
        switch error.kind {
        case .invalidInput, .storage, .notConfigured, .invalidAddress:
            // Already about the file or the address, and already in full.
            return PlainLanguage.message(for: error)
        case .cancelled, .transport, .http, .invalidResponse, .decoding, .notAnImage, .verification, .unexpected:
            return "Il file non è stato letto dal server, quindi non è stato importato nulla. " + PlainLanguage.message(for: error)
        }
    }
}
