import Foundation
import Observation
import SwiftData

/// Takes a search result from "not on the server" to "downloaded on this iPhone":
/// POST /downloads, poll GET /downloads until the job is done, sync the library so
/// the track arrives with its hash and size, then hand it to `DownloadManager`.
///
/// Resumable by construction: every step starts from what is stored in its
/// `PendingAcquisition` and what the server reports, never from memory, and each
/// stage change is saved before the step that follows it. A relaunch, or a return
/// to the foreground, runs the same steps again from wherever the record stopped.
///
/// Runs only in the foreground, as one loop that stops as soon as nothing is in
/// progress. Never starts playback.
@Observable
final class AcquisitionCoordinator {
    /// The last failure outside any single record, e.g. the store could not be read.
    private(set) var lastError: APIError?
    /// For the technical details: whether the loop is running, and its last poll.
    private(set) var isRunning = false
    private(set) var lastPollAt: Date?
    private(set) var pollProblem: String?

    /// Between polls of GET /downloads while the server is working.
    static let serverPollInterval: Double = 2
    /// Between checks while the device download is starting.
    static let handoffCheckInterval: Double = 1
    /// Consecutive failed polls before the records waiting on the server fail.
    static let maxPollFailures = 3
    /// How long the device download may take to report anything once asked.
    static let handoffStartDeadline: TimeInterval = 20
    /// POST attempts for one acquisition before a lost job counts as a failure.
    static let maxRequestAttempts = 3

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sync: LibrarySync
    @ObservationIgnored private let downloads: DownloadManager

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loopToken = UUID()
    @ObservationIgnored private var inForeground = false
    /// Changes whenever the app leaves the foreground. A step that was waiting on
    /// the network when it changed ignores its error: the request was interrupted
    /// by iOS, not refused by the server, and the step runs again on return.
    @ObservationIgnored private var foregroundGeneration = 0
    @ObservationIgnored private var pollFailures = 0
    /// Video ids whose device download was requested by this process, so a refusal
    /// or a silent start is attributed to this handoff and not an older action.
    @ObservationIgnored private var handoffsThisProcess = Set<String>()

    init(context: ModelContext, settings: AppSettings, sync: LibrarySync, downloads: DownloadManager) {
        self.context = context
        self.settings = settings
        self.sync = sync
        self.downloads = downloads
    }

    // MARK: - Lifecycle

    /// The app is in the foreground: continue whatever is pending.
    func resume() {
        inForeground = true
        startLoopIfNeeded()
    }

    /// The app left the foreground: stop polling. Records keep their stage.
    func pause() {
        inForeground = false
        foregroundGeneration += 1
        loop?.cancel()
        loop = nil
        isRunning = false
    }

    // MARK: - Actions from the UI

    /// Starts acquiring a search result. Does nothing for a track already being
    /// acquired; a track already in the library goes straight to the device download.
    func acquire(_ song: SongResult) {
        lastError = nil
        if let track = storedTrack(song.videoID) {
            switch track.downloadState {
            case .notDownloaded, .failed, .cancelled:
                if downloads.preflights[track.serverID] == nil {
                    downloads.download(track)
                }
            case .queued, .downloading, .downloaded:
                break
            }
            return
        }
        guard pendingRecord(song.videoID) == nil else { return }
        let record = PendingAcquisition(
            videoID: song.videoID,
            title: song.title,
            artist: song.artist,
            album: song.album,
            durationS: song.durationS,
            artworkURL: song.artworkURLSmall ?? song.artworkURL
        )
        context.insert(record)
        guard save("recording the request for “\(song.title ?? song.videoID)”") else { return }
        startLoopIfNeeded()
    }

    /// Picks a failed acquisition up again from the step that failed.
    func retry(videoID: String) {
        lastError = nil
        guard let record = pendingRecord(videoID), record.stage == .failed else { return }
        switch record.failure {
        case .serverDownloadFailed, .serverCancelled, .serverLostJob:
            // The job is over: ask for a new one.
            record.jobID = nil
            record.requestSentAt = nil
            record.requestAttempts = 0
            record.stage = .requesting
        case .syncFailed, .notInLibrary:
            record.syncAttempts = 0
            record.stage = .syncing
        case .deviceDownloadRefused:
            record.handoffRequestedAt = nil
            record.stage = .handingOff
        case .noAddress, .unreachable, .serverRejected, .unreadableResponse, .storage, .unexpected, nil:
            // Wherever it was: a known job is polled, otherwise the request is made,
            // or looked up first if it may already have been sent.
            record.stage = record.jobID == nil ? .requesting : .onServer
        }
        pollFailures = 0
        handoffsThisProcess.remove(videoID)
        guard save("retrying “\(record.title ?? videoID)”") else { return }
        startLoopIfNeeded()
    }

    /// Forgets a failed acquisition.
    func remove(videoID: String) {
        lastError = nil
        guard let record = pendingRecord(videoID) else { return }
        context.delete(record)
        save("removing “\(record.title ?? videoID)”")
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Loop

    private func startLoopIfNeeded() {
        guard inForeground, loop == nil, !activeRecords().isEmpty else { return }
        let token = UUID()
        loopToken = token
        isRunning = true
        loop = Task { [weak self] in
            await self?.run(token: token)
        }
    }

    private func run(token: UUID) async {
        defer {
            // A pause followed by a resume may already have started a new loop.
            if loopToken == token {
                loop = nil
                isRunning = false
                // Something tapped while this pass was deciding to stop.
                startLoopIfNeeded()
            }
        }
        while !Task.isCancelled {
            guard let delay = await step() else { return }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Cancelled by pause(); the records keep their stage.
                return
            }
        }
    }

    /// One pass over every active record. Returns the delay before the next pass,
    /// or nil when nothing is left to do.
    private func step() async -> Double? {
        let generation = foregroundGeneration

        for videoID in activeRecords().filter({ $0.stage == .requesting }).map(\.videoID) {
            await request(videoID, generation: generation)
            guard generation == foregroundGeneration else { return nil }
        }

        if activeRecords().contains(where: { $0.stage == .onServer }) {
            await pollServer(generation: generation)
            guard generation == foregroundGeneration else { return nil }
        }

        if activeRecords().contains(where: { $0.stage == .syncing }) {
            await syncPending(generation: generation)
            guard generation == foregroundGeneration else { return nil }
        }

        handOff()

        let remaining = activeRecords()
        if remaining.isEmpty {
            return nil
        }
        if remaining.contains(where: { $0.stage == .requesting || $0.stage == .onServer }) {
            // Back off while polls fail: 2, 4, 8 s.
            return Self.serverPollInterval * pow(2, Double(min(pollFailures, 3)))
        }
        return Self.handoffCheckInterval
    }

    // MARK: - Steps

    /// POST /downloads, or, when a POST may already have reached the server, the
    /// matching job looked up first.
    private func request(_ videoID: String, generation: Int) async {
        guard let record = pendingRecord(videoID), record.stage == .requesting else { return }
        let client: APIClient
        do {
            client = try settings.makeClient()
        } catch {
            fail(record, .noAddress, .from(error))
            return
        }

        if record.requestSentAt != nil {
            let jobs: APIResponse<[ServerJob]>
            do {
                jobs = try await client.downloadJobs()
            } catch {
                guard generation == foregroundGeneration, let current = pendingRecord(videoID), current.stage == .requesting else { return }
                let apiError = APIError.from(error)
                fail(current, Self.cause(of: apiError), apiError)
                return
            }
            guard let current = pendingRecord(videoID), current.stage == .requesting else { return }
            if let job = Self.newestLiveJob(for: videoID, in: jobs.value) {
                adopt(job, into: current)
                save("recording the server job for “\(current.title ?? videoID)”")
                return
            }
        }

        guard let current = pendingRecord(videoID), current.stage == .requesting else { return }
        if current.requestAttempts >= Self.maxRequestAttempts {
            fail(current, .serverLostJob, APIError(
                kind: .invalidResponse,
                title: "The server kept losing the download job",
                url: nil,
                details: ["POST /downloads was sent \(current.requestAttempts) times for \(videoID), and each job disappeared from GET /downloads."]
            ))
            return
        }
        current.requestSentAt = Date()
        current.requestAttempts += 1
        guard save("recording that the download request was sent") else { return }

        let response: APIResponse<DownloadRequestResult>
        do {
            response = try await client.requestDownload(videoID: videoID)
        } catch {
            // requestSentAt stays set: if the server did receive it, the next
            // attempt finds the job instead of queueing a second one.
            guard generation == foregroundGeneration, let failed = pendingRecord(videoID), failed.stage == .requesting else { return }
            let apiError = APIError.from(error)
            fail(failed, Self.cause(of: apiError), apiError)
            return
        }

        // A successful reply is applied even if the app left the foreground meanwhile.
        guard let answered = pendingRecord(videoID), answered.stage == .requesting else { return }
        if response.status == 200 || response.value.status == "exists" {
            // The server already has it: no server phase.
            answered.stage = .syncing
            answered.syncAttempts = 0
        } else if let jobID = response.value.jobID {
            answered.jobID = jobID
            answered.serverJobState = ServerJob.State.queued.rawValue
            answered.serverProgress = 0
            answered.serverError = nil
            answered.stage = .onServer
        } else {
            fail(answered, .unreadableResponse, APIError(
                kind: .invalidResponse,
                title: "The server's reply to the download request had neither a job nor a track",
                url: response.url.absoluteString,
                details: ["HTTP status: \(response.status)", "Body: \(response.bodyText)"]
            ))
            return
        }
        save("recording the server's reply for “\(answered.title ?? videoID)”")
    }

    /// One GET /downloads for every record waiting on the server.
    private func pollServer(generation: Int) async {
        let client: APIClient
        do {
            client = try settings.makeClient()
        } catch {
            let apiError = APIError.from(error)
            for record in activeRecords() where record.stage == .onServer {
                fail(record, .noAddress, apiError)
            }
            return
        }

        let response: APIResponse<[ServerJob]>
        do {
            response = try await client.downloadJobs()
        } catch {
            guard generation == foregroundGeneration else { return }
            let apiError = APIError.from(error)
            pollFailures += 1
            pollProblem = "Poll \(pollFailures) of \(Self.maxPollFailures) failed at \(Formatting.time(Date())): \(apiError.oneLine)"
            guard pollFailures >= Self.maxPollFailures else { return }
            pollFailures = 0
            for record in activeRecords() where record.stage == .onServer {
                fail(record, Self.cause(of: apiError), apiError)
            }
            return
        }
        pollFailures = 0
        pollProblem = nil
        lastPollAt = Date()

        let jobsByID = Dictionary(response.value.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in activeRecords() where record.stage == .onServer {
            guard let jobID = record.jobID, let job = jobsByID[jobID], job.trackID == record.videoID else {
                // The job id is unknown to this server: it was replaced or reset.
                if let job = Self.newestLiveJob(for: record.videoID, in: response.value) {
                    adopt(job, into: record)
                } else {
                    record.jobID = nil
                    record.requestSentAt = nil
                    record.stage = .requesting
                }
                continue
            }
            record.serverJobState = job.state
            record.serverProgress = job.progress
            record.serverError = job.error
            switch job.knownState {
            case .queued, .running:
                break
            case .done:
                record.stage = .syncing
                record.syncAttempts = 0
            case .failed:
                fail(record, .serverDownloadFailed, APIError(
                    kind: .unexpected,
                    title: "The server could not download the track",
                    url: response.url.absoluteString,
                    details: ["Job \(job.id) for \(record.videoID) failed.", "Server error: \(job.error ?? "(none given)")"]
                ), saving: false)
            case .cancelled:
                fail(record, .serverCancelled, APIError(
                    kind: .unexpected,
                    title: "The download was cancelled on the server",
                    url: response.url.absoluteString,
                    details: ["Job \(job.id) for \(record.videoID) is cancelled."]
                ), saving: false)
            case nil:
                fail(record, .unreadableResponse, APIError(
                    kind: .invalidResponse,
                    title: "The server reported an unknown job state",
                    url: response.url.absoluteString,
                    details: ["Job \(job.id) has state \"\(job.state)\", which this app does not know."]
                ), saving: false)
            }
        }
        save("recording server download progress")
    }

    /// A library sync, then each record whose track has arrived moves on.
    private func syncPending(generation: Int) async {
        // Joins a sync already running. If that one started before the track
        // existed, the next pass syncs again (see syncAttempts).
        await sync.refresh()
        guard generation == foregroundGeneration else { return }

        for record in activeRecords() where record.stage == .syncing {
            if let track = storedTrack(record.videoID), track.sha256 != nil {
                record.handoffRequestedAt = nil
                record.stage = .handingOff
                continue
            }
            if case .failed(let error) = sync.status {
                fail(record, .syncFailed, error, saving: false)
                continue
            }
            record.syncAttempts += 1
            if record.syncAttempts >= 2 {
                fail(record, .notInLibrary, APIError(
                    kind: .invalidResponse,
                    title: "The track is not in the library after syncing",
                    url: nil,
                    details: [
                        "The server reported \(record.videoID) as downloaded, but \(record.syncAttempts) library syncs did not include it with a SHA-256.",
                        "The server may list the track as deleted, or without an album.",
                    ]
                ), saving: false)
            }
        }
        save("recording the library sync result")
    }

    /// Hands each track now in the library to the existing device download, and
    /// forgets the record once that download owns it.
    private func handOff() {
        var changed = false
        for record in activeRecords() where record.stage == .handingOff {
            guard let track = storedTrack(record.videoID) else {
                // Gone again, e.g. removed by a full sync: fetch it again.
                record.syncAttempts = 0
                record.stage = .syncing
                changed = true
                continue
            }
            let id = track.serverID
            if downloads.preflights[id] != nil {
                continue
            }
            let requestedHere = handoffsThisProcess.contains(record.videoID)
            if requestedHere, let refusal = downloads.refusals[id] {
                handoffsThisProcess.remove(record.videoID)
                fail(record, .deviceDownloadRefused, refusal, saving: false)
                changed = true
                continue
            }
            let changedSinceRequest = record.handoffRequestedAt.map { (track.stateChangedAt ?? .distantPast) >= $0 } ?? false

            switch track.downloadState {
            case .queued, .downloading, .downloaded:
                finish(record)
                changed = true
            case .notDownloaded, .failed, .cancelled:
                if changedSinceRequest && track.downloadState != .notDownloaded {
                    // The device download started and failed: its own row shows why.
                    finish(record)
                    changed = true
                } else if requestedHere, let requested = record.handoffRequestedAt {
                    if Date().timeIntervalSince(requested) > Self.handoffStartDeadline {
                        handoffsThisProcess.remove(record.videoID)
                        fail(record, .deviceDownloadRefused, APIError(
                            kind: .unexpected,
                            title: "The download on this iPhone did not start",
                            url: nil,
                            details: ["Asked at \(Formatting.time(requested)); after \(Int(Self.handoffStartDeadline)) s the track was still \(track.downloadState.label.lowercased()), with no pre-flight check and no refusal."]
                        ), saving: false)
                        changed = true
                    }
                } else {
                    // First request, or the app was relaunched before the download
                    // reported anything: ask (again).
                    record.handoffRequestedAt = Date()
                    handoffsThisProcess.insert(record.videoID)
                    changed = true
                    downloads.download(track)
                }
            }
        }
        if changed {
            save("handing tracks to the device download")
        }
    }

    // MARK: - Helpers

    private func adopt(_ job: ServerJob, into record: PendingAcquisition) {
        record.jobID = job.id
        record.serverJobState = job.state
        record.serverProgress = job.progress
        record.serverError = job.error
        if job.knownState == .done {
            record.stage = .syncing
            record.syncAttempts = 0
        } else {
            record.stage = .onServer
        }
    }

    private func finish(_ record: PendingAcquisition) {
        handoffsThisProcess.remove(record.videoID)
        context.delete(record)
    }

    private func fail(_ record: PendingAcquisition, _ failure: AcquisitionFailure, _ error: APIError, saving: Bool = true) {
        record.stage = .failed
        record.failure = failure
        record.failureMessage = Self.message(for: failure, error: error)
        record.errorText = error.fullText
        if saving {
            save("recording a failed acquisition")
        }
    }

    /// The newest job for the video that is still going or finished.
    static func newestLiveJob(for videoID: String, in jobs: [ServerJob]) -> ServerJob? {
        jobs
            .filter { job in
                guard job.trackID == videoID else { return false }
                switch job.knownState {
                case .queued, .running, .done: return true
                case .failed, .cancelled, nil: return false
                }
            }
            .max { $0.id < $1.id }
    }

    static func cause(of error: APIError) -> AcquisitionFailure {
        switch error.kind {
        case .notConfigured, .invalidAddress: return .noAddress
        case .transport, .cancelled: return .unreachable
        case .http: return .serverRejected
        case .invalidResponse, .decoding, .notAnImage: return .unreadableResponse
        case .storage, .verification: return .storage
        case .invalidInput, .unexpected: return .unexpected
        }
    }

    /// What failed and what to check, readable without the technical details.
    static func message(for failure: AcquisitionFailure, error: APIError) -> String {
        switch failure {
        case .noAddress:
            return "Nessun indirizzo del server valido. Impostalo in Impostazioni, poi tocca Riprova."
        case .unreachable:
            return "Impossibile raggiungere il server. Controlla l'indirizzo in Impostazioni, che il server sia acceso e che Tailscale sia connesso, poi tocca Riprova."
        case .serverRejected:
            return "Il server ha rifiutato la richiesta di download. Controlla che l'indirizzo punti al backend Prisma e che sia aggiornato."
        case .unreadableResponse:
            return "La risposta del server non è leggibile: app e backend potrebbero non essere allineati. Aggiorna il backend, poi tocca Riprova."
        case .serverDownloadFailed:
            return "Il server non è riuscito a scaricare il brano da YouTube. Riprova più tardi; se succede con ogni brano, yt-dlp sul server va aggiornato."
        case .serverCancelled:
            return "Il download è stato annullato sul server. Tocca Riprova per richiederlo di nuovo."
        case .serverLostJob:
            return "Il server ha perso traccia della richiesta, forse perché è stato riavviato o reinstallato. Tocca Riprova."
        case .syncFailed:
            return "Il brano è sul server, ma la sincronizzazione della libreria non è riuscita: "
                + PlainLanguage.summary(for: error).lowercasedFirst + ". Tocca Riprova."
        case .notInLibrary:
            return "Il server dice di avere il brano, ma non compare nella libreria. Prova Risincronizza tutto in Libreria, poi tocca Riprova."
        case .deviceDownloadRefused:
            return "Il brano è in libreria, ma il download sul telefono non è partito: "
                + PlainLanguage.summary(for: error).lowercasedFirst + ". Tocca Riprova."
        case .storage:
            return "Non è stato possibile salvare sul telefono. Controlla lo spazio libero, poi tocca Riprova."
        case .unexpected:
            return "Errore imprevisto durante la richiesta al server. Tocca Riprova; se si ripete, apri i dettagli tecnici."
        }
    }

    private func activeRecords() -> [PendingAcquisition] {
        allRecords().filter(\.isActive)
    }

    private func allRecords() -> [PendingAcquisition] {
        do {
            return try context.fetch(FetchDescriptor<PendingAcquisition>(sortBy: [SortDescriptor(\.createdAt)]))
        } catch {
            lastError = .storage("Could not read the tracks being acquired", location: nil, error: error)
            return []
        }
    }

    private func pendingRecord(_ videoID: String) -> PendingAcquisition? {
        allRecords().first { $0.videoID == videoID && !$0.isDeleted }
    }

    private func storedTrack(_ videoID: String) -> StoredTrack? {
        var descriptor = FetchDescriptor<StoredTrack>(predicate: #Predicate<StoredTrack> { $0.serverID == videoID })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            lastError = .storage("Could not look up \(videoID) in the local library", location: nil, error: error)
            return nil
        }
    }

    @discardableResult
    private func save(_ activity: String) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            lastError = .storage("Saving failed while \(activity)", location: nil, error: error)
            return false
        }
    }
}
