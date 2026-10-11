import Foundation
import Observation
import SwiftData

/// Takes a track from "nowhere" to wherever the user chose to keep it:
/// POST /downloads, poll GET /downloads until the job is done, sync the library so
/// the track arrives with its hash and size, hand it to `DownloadManager`, and -
/// for Telefono - delete the server's copy once the phone's is verified.
///
/// The destination decides where the chain stops. Server stops at the sync, with no
/// file on the phone. Entrambi stops when the device download owns the track.
/// Telefono goes one step further, and that step is the only one in the app that
/// destroys the other copy, so its order is fixed: the server's copy is deleted
/// **after** the device download has reached `downloaded`, which is the state
/// `DownloadFinalizer` produces only once the received file matched its SHA-256.
/// Nothing here verifies anything itself; it reads that state, and refuses to act
/// without it.
///
/// Resumable by construction: every step starts from what is stored in its
/// `PendingAcquisition` and what the server reports, never from memory, and each
/// stage change is saved before the step that follows it. A relaunch, or a return
/// to the foreground, runs the same steps again from wherever the record stopped.
///
/// Runs only in the foreground, as one loop that stops as soon as nothing is in
/// progress. Never starts playback.
///
/// Only an answer fails a record. A job the server reports as failed, a request it
/// refuses, a reply that cannot be read: those are answers, and the record that got
/// one is failed and shown as failed. A request that reached nobody — the server is
/// off, the network is, the address is missing, the server answered that it is
/// itself in trouble — is not one (`isUnreachable`). The record stays exactly where
/// it was, the pass stops there so that nothing else is sent into the void, and the
/// chain goes on from the same step when `ServerReachability` reports the server
/// back or the app returns to the foreground. That is not a retry: nothing failed.
/// A record that did fail is never picked up again by anything but the user.
@Observable
final class AcquisitionCoordinator {
    /// The last failure outside any single record, e.g. the store could not be read.
    private(set) var lastError: APIError?
    /// For the technical details: whether the loop is running, and its last poll.
    private(set) var isRunning = false
    private(set) var lastPollAt: Date?
    /// Requests in a row that reached nobody. Above zero, the records waiting on
    /// the server are waiting for the server itself, and their rows say so. Back to
    /// zero the moment anything is answered. (The name is older than the meaning:
    /// it used to count failed polls only.)
    private(set) var pollFailures = 0
    /// Why the records are waiting, while they are: the server could not be
    /// reached, and how. Not `lastError`, because nothing failed and nobody has to
    /// close it: the first answer from the server withdraws it.
    private(set) var unreachableNotice: APIError?
    /// When the server said its download queue starts again, while it is resting
    /// after YouTube's bot wall; nil when it is not resting, or when nothing has
    /// had a reason to ask. Read by the rows of the tracks waiting in that queue,
    /// so half an hour of "in coda" says why and until when.
    private(set) var serverCooldownUntil: Date?

    /// Between polls of GET /downloads while the server is working.
    static let serverPollInterval: Double = 2
    /// Between checks while the device download is starting.
    static let handoffCheckInterval: Double = 1
    /// Consecutive polls the server answered with something that is not a list of
    /// jobs — an error status, an unreadable body — before the records waiting on it
    /// fail. A poll that reached nobody is not counted here and fails nothing.
    static let maxPollFailures = 3
    /// The longest pause between two attempts while the server is said to be
    /// reachable and still does not answer this chain: 2, 4, 8 … up to this.
    static let longestUnansweredPause: Double = 64
    /// How far a server's clock and this phone's may disagree when deciding whether
    /// a job was created by a request this phone sent.
    static let clockSkewAllowance: TimeInterval = 10
    /// How long the device download may take to report anything once asked.
    static let handoffStartDeadline: TimeInterval = 20
    /// POST attempts for one acquisition before a lost job counts as a failure.
    static let maxRequestAttempts = 3
    /// DELETE attempts against a server that keeps answering 409 (busy) before the
    /// step gives up. The verified file is on the phone throughout, so giving up
    /// costs the user nothing but space on the server.
    static let maxDeletionAttempts = 10
    /// How long this phone's jobs may sit queued with nothing running on the
    /// server before /health is asked whether the queue is resting. Longer than the
    /// 12-20 s the server leaves between two downloads anyway, so an ordinary gap
    /// asks nothing.
    static let queueIdleBeforeAsking: TimeInterval = 25
    /// At most one such question in this long.
    static let cooldownCheckInterval: TimeInterval = 60

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sync: LibrarySync
    @ObservationIgnored private let downloads: DownloadManager
    /// Every acquisition adds its track to Preferiti, whatever the destination and
    /// before anything is fetched, so the collection is right even if the chain
    /// never finishes.
    @ObservationIgnored private let playlists: PlaylistStore
    /// Asked to look again whenever a request of this chain reaches nobody, so that
    /// its answer turns to "unreachable" and its later turn back is an event.
    @ObservationIgnored private let reachability: ServerReachability

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loopToken = UUID()
    @ObservationIgnored private var inForeground = false
    /// Changes whenever the app leaves the foreground. A step that was waiting on
    /// the network when it changed ignores its error: the request was interrupted
    /// by iOS, not refused by the server, and the step runs again on return.
    @ObservationIgnored private var foregroundGeneration = 0
    /// Video ids whose device download was requested by this process, so a refusal
    /// or a silent start is attributed to this handoff and not an older action.
    @ObservationIgnored private var handoffsThisProcess = Set<String>()
    /// Since when the polls have shown jobs of this phone queued and none running.
    @ObservationIgnored private var queueIdleSince: Date?
    @ObservationIgnored private var cooldownAskedAt: Date?
    /// The one /health request in flight, so a second is never started beside it.
    @ObservationIgnored private var cooldownCheck: Task<Void, Never>?
    /// Set by the pass in progress when one of its requests reached nobody: the
    /// rest of the pass sends nothing more.
    @ObservationIgnored private var unanswered = false
    /// Polls in a row answered with something other than the jobs.
    @ObservationIgnored private var unreadablePolls = 0

    init(
        context: ModelContext,
        settings: AppSettings,
        sync: LibrarySync,
        downloads: DownloadManager,
        playlists: PlaylistStore,
        reachability: ServerReachability
    ) {
        self.context = context
        self.settings = settings
        self.sync = sync
        self.downloads = downloads
        self.playlists = playlists
        self.reachability = reachability
    }

    /// The records waiting on the server are waiting for the server itself.
    var isWaitingForServer: Bool {
        pollFailures > 0
    }

    // MARK: - Lifecycle

    /// The app is in the foreground: continue whatever is pending.
    func resume() {
        inForeground = true
        startLoopIfNeeded()
    }

    /// `ServerReachability` reports the server back. Whatever was left where it was
    /// when the server went away goes on from there.
    ///
    /// The loop is either gone, parked until exactly this, and is started; or still
    /// there, sleeping out the pause after a request that reached nobody, and is
    /// replaced so that the news is acted on now rather than a minute from now. A
    /// request that loop still had in flight is disowned the way `pause` disowns
    /// one: its error is ignored, and the record it was for is looked at again.
    func serverBecameReachable() {
        guard inForeground else { return }
        if loop != nil, isWaitingForServer {
            foregroundGeneration += 1
            loop?.cancel()
            loop = nil
            isRunning = false
        }
        startLoopIfNeeded()
    }

    /// The user asked whether the server is back, from the notice that says it is
    /// not. One probe, and one more attempt at whatever is waiting.
    func checkServer() {
        reachability.retry()
        startLoopIfNeeded()
    }

    /// The app left the foreground: stop polling. Records keep their stage.
    func pause() {
        inForeground = false
        foregroundGeneration += 1
        loop?.cancel()
        loop = nil
        isRunning = false
        // Time spent in the background is not time spent watching the queue.
        queueIdleSince = nil
    }

    // MARK: - Actions from the UI

    /// Adds the track to Preferiti and acquires it to `destination`.
    ///
    /// The favourite is created first and unconditionally: Preferiti is the
    /// collection, and it is honest about a track that is nowhere yet. What the
    /// chain then has to do depends on what already exists, which is why the
    /// starting stage is worked out rather than assumed.
    func acquire(_ request: AcquisitionRequest, destination: AcquisitionDestination) {
        lastError = nil
        playlists.addFavourite(request.draft)

        if let existing = pendingRecord(request.videoID) {
            // Already on its way. A failed one is picked up again with the newly
            // chosen destination; a running one keeps the one it started with.
            if existing.stage == .failed {
                existing.destination = destination
                save("recording the new destination for “\(request.name)”")
                retry(videoID: request.videoID)
            } else {
                save("adding “\(request.name)” to the favourites")
            }
            return
        }

        guard let stage = startingStage(for: destination, track: storedTrack(request.videoID)) else {
            // Nothing left to fetch: the favourite alone was the change.
            save("adding “\(request.name)” to the favourites")
            return
        }

        let record = PendingAcquisition(
            videoID: request.videoID,
            title: request.title,
            artist: request.artist,
            album: request.albumName,
            durationS: request.durationS,
            artworkURL: request.artworkURL,
            destination: destination
        )
        record.stage = stage
        context.insert(record)
        guard save("recording the request for “\(request.name)”") else { return }
        startLoopIfNeeded()
    }

    /// The same for many tracks at once, in the order given: what importing a
    /// playlist asks for.
    ///
    /// Nothing here talks to the server, so fifty tracks cost one save and return at
    /// once. Each track that has something left to fetch gets its record, and the
    /// records are stamped a millisecond apart so that their order is the order
    /// given and not whatever two equal timestamps would sort to. The loop then does
    /// what it does for any record: one `POST /downloads` at a time, each awaited
    /// before the next, in that order — which is therefore the order of the server's
    /// queue — and after that one `GET /downloads` per pass for all of them
    /// together. A track the server already has skips the request and goes straight
    /// to the device download, and one already on the phone gets no record at all:
    /// `startingStage` decides both, exactly as for a single track.
    ///
    /// An id listed twice is acquired once. A track whose earlier acquisition failed
    /// is picked up again, as it is when its own row is asked for a second time:
    /// this is the user asking, not the app retrying by itself.
    func acquire(_ requests: [AcquisitionRequest], destination: AcquisitionDestination) {
        lastError = nil
        let existing = Dictionary(
            allRecords().filter { !$0.isDeleted }.map { ($0.videoID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let now = Date()
        var seen = Set<String>()
        var created = 0
        var failedEarlier: [String] = []
        for request in requests {
            guard seen.insert(request.videoID).inserted else { continue }
            playlists.addFavourite(request.draft)

            if let record = existing[request.videoID] {
                // Already on its way; a failed one takes the new destination.
                if record.stage == .failed {
                    record.destination = destination
                    failedEarlier.append(request.videoID)
                }
                continue
            }
            guard let stage = startingStage(for: destination, track: storedTrack(request.videoID)) else {
                // Nothing left to fetch: the favourite alone was the change.
                continue
            }
            let record = PendingAcquisition(
                videoID: request.videoID,
                title: request.title,
                artist: request.artist,
                album: request.albumName,
                durationS: request.durationS,
                artworkURL: request.artworkURL,
                destination: destination
            )
            record.stage = stage
            record.createdAt = now.addingTimeInterval(Double(created) / 1000)
            context.insert(record)
            created += 1
        }
        guard save("recording the requests for \(seen.count) tracks") else { return }
        for videoID in failedEarlier {
            retry(videoID: videoID)
        }
        startLoopIfNeeded()
    }

    /// Where the chain has to start for this destination, given what the phone
    /// already has, or nil when there is nothing left to do.
    ///
    /// "On the server" is a track with a library row the server has not dropped:
    /// `serverDroppedAt` is set only once a sync saw the server let go of a copy
    /// this phone had claimed, and such a track has to be asked for again rather
    /// than downloaded, because the server's file is gone. `POST /downloads` revives
    /// a soft-deleted track, so asking again is all it takes.
    private func startingStage(for destination: AcquisitionDestination, track: StoredTrack?) -> AcquisitionStage? {
        guard let track else { return .requesting }
        let onPhone = track.downloadState == .downloaded
        let onServer = track.serverDroppedAt == nil
        // Without a hash the device download could not verify anything, so the
        // library is synced first to fetch one.
        let deviceStage: AcquisitionStage = track.sha256 == nil ? .syncing : .handingOff

        switch destination {
        case .phone:
            if onPhone { return onServer ? .deletingFromServer : nil }
            return onServer ? deviceStage : .requesting
        case .server:
            return onServer ? nil : .requesting
        case .both:
            if !onServer { return .requesting }
            return onPhone ? nil : deviceStage
        }
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
        case .serverDeletionFailed:
            // The file is on the phone and verified; only the server's copy is left.
            record.deletionAttempts = 0
            record.stage = .deletingFromServer
        case .noAddress, .unreachable, .serverRejected, .unreadableResponse, .storage, .unexpected, nil:
            // Wherever it was: a known job is polled, otherwise the request is made,
            // or looked up first if it may already have been sent.
            record.stage = record.jobID == nil ? .requesting : .onServer
        }
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
        // Stopped on purpose with records still pending, to wait for the server.
        var parked = false
        defer {
            // A pause followed by a resume may already have started a new loop.
            if loopToken == token {
                loop = nil
                isRunning = false
                if !parked {
                    // Something tapped while this pass was deciding to stop.
                    startLoopIfNeeded()
                }
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
            // A request of that pass reached nobody, and by now the probe it set
            // off has usually answered. If the answer is that the server is not
            // there, this loop ends here with every record where it was: there is
            // nothing to poll, and what ends the wait is an event —
            // `serverBecameReachable`, or the app coming back to the foreground —
            // never a timer. If the answer is that the server is there, it was one
            // lost request, or something only this chain cannot reach, and the pass
            // is simply run again after the pause above, which grows each time.
            if unanswered, reachability.isReachable == false {
                parked = true
                return
            }
        }
    }

    /// One pass over every active record. Returns the delay before the next pass,
    /// or nil when nothing is left to do.
    ///
    /// The steps run in the order of the chain, and every one of them after a
    /// request that reached nobody is skipped: the first `POST` that cannot reach
    /// the server is the last thing this pass sends, so fifty records do not each
    /// wait out their own timeout, and no device download is handed over to fail its
    /// pre-flight against a server known to be away.
    private func step() async -> Double? {
        let generation = foregroundGeneration
        unanswered = false

        for videoID in activeRecords().filter({ $0.stage == .requesting }).map(\.videoID) {
            await request(videoID, generation: generation)
            guard generation == foregroundGeneration else { return nil }
            if unanswered { break }
        }

        if !unanswered, activeRecords().contains(where: { $0.stage == .onServer }) {
            await pollServer(generation: generation)
            guard generation == foregroundGeneration else { return nil }
        }

        if !unanswered, activeRecords().contains(where: { $0.stage == .syncing }) {
            await syncPending(generation: generation)
            guard generation == foregroundGeneration else { return nil }
        }

        if !unanswered {
            handOff()
        }

        if !unanswered, activeRecords().contains(where: { $0.stage == .deletingFromServer }) {
            await deleteServerCopies(generation: generation)
            guard generation == foregroundGeneration else { return nil }
        }

        let remaining = activeRecords()
        if remaining.isEmpty {
            // Nothing of this phone's is waiting in the server's queue any more,
            // nor for the server.
            queueIdleSince = nil
            forgetCooldown()
            forgetWaiting()
            return nil
        }
        if unanswered {
            // 2, 4, 8 … s. `run` decides after it whether there is anyone to ask.
            let doublings = Double(min(max(pollFailures, 1) - 1, 8))
            return min(Self.longestUnansweredPause, Self.serverPollInterval * pow(2, doublings))
        }
        if remaining.contains(where: { $0.stage == .requesting || $0.stage == .onServer }) {
            return Self.serverPollInterval
        }
        if remaining.contains(where: { $0.stage == .deletingFromServer }) {
            // A 409 means the server is busy with this track or with its library, so
            // asking again a second later would only find it busy again.
            return Self.serverPollInterval
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
            // No address is nobody to ask. The record waits; the notice says why.
            serverDidNotAnswer(.from(error))
            return
        }

        // A request for this record went out before and nothing is known of what
        // became of it: the app was closed, or the request timed out — and a
        // request that timed out may still have arrived. The server makes a new job
        // for every POST it receives for a track it does not have, so asking again
        // blindly could queue the track twice. What the server lists decides — and
        // it is asked for every job it has, not only the recent ones, because the
        // phone may have been away for longer than the server keeps a finished job
        // in its short list.
        if let sentAt = record.requestSentAt {
            let jobs: APIResponse<[ServerJob]>
            do {
                jobs = try await client.downloadJobs(all: true)
            } catch {
                guard generation == foregroundGeneration, let current = pendingRecord(videoID), current.stage == .requesting else { return }
                let apiError = APIError.from(error)
                if Self.isUnreachable(apiError) {
                    serverDidNotAnswer(apiError)
                } else {
                    serverAnswered()
                    fail(current, Self.cause(of: apiError), apiError)
                }
                return
            }
            serverAnswered()
            guard let current = pendingRecord(videoID), current.stage == .requesting else { return }
            if let job = Self.newestLiveJob(for: videoID, in: jobs.value, since: sentAt) {
                adopt(job, into: current)
                save("recording the server job for “\(current.title ?? videoID)”")
                return
            }
            // No job still going. If one made by that request has already ended
            // badly, the request did arrive and this is its outcome: a failure, to
            // be shown as one. Asking again here would be the app retrying a failed
            // download by itself, which it never does.
            if let ended = Self.newestEndedJob(for: videoID, in: jobs.value, since: sentAt) {
                failForEndedJob(current, ended, url: jobs.url.absoluteString)
                save("recording how the server job for “\(current.title ?? videoID)” ended")
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
            if Self.isUnreachable(apiError) {
                // Nobody answered, so this attempt proves nothing about the server
                // losing jobs and is not counted as one. The record stays
                // `requesting`, in its place, and the look-up above speaks first
                // when the chain goes on.
                failed.requestAttempts = max(0, failed.requestAttempts - 1)
                save("recording that the download request got no answer")
                serverDidNotAnswer(apiError)
            } else {
                serverAnswered()
                fail(failed, Self.cause(of: apiError), apiError)
            }
            return
        }
        serverAnswered()

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
            serverDidNotAnswer(.from(error))
            return
        }

        let response: APIResponse<[ServerJob]>
        do {
            response = try await client.downloadJobs()
        } catch {
            guard generation == foregroundGeneration else { return }
            let apiError = APIError.from(error)
            if Self.isUnreachable(apiError) {
                // The jobs are where they were, on a server that cannot be asked.
                // Nothing fails for that, however many times it happens.
                serverDidNotAnswer(apiError)
                return
            }
            // It answered, with something that is not the jobs.
            serverAnswered()
            unreadablePolls += 1
            guard unreadablePolls >= Self.maxPollFailures else { return }
            unreadablePolls = 0
            for record in activeRecords() where record.stage == .onServer {
                fail(record, Self.cause(of: apiError), apiError)
            }
            return
        }
        serverAnswered()
        unreadablePolls = 0
        lastPollAt = Date()

        let jobsByID = Dictionary(response.value.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var jobFailed = false
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
                jobFailed = true
                fail(record, .serverDownloadFailed, APIError(
                    kind: .unexpected,
                    title: "The server could not download the track",
                    url: response.url.absoluteString,
                    details: ["Job \(job.id) for \(record.videoID) failed.", "Server error: \(job.error ?? "(none given)")"],
                    message: Self.serverFailureMessage(job.error)
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
        considerCooldown(jobs: response.value, jobFailed: jobFailed)
    }

    /// Decides, from the poll that just came back, whether to ask the server if its
    /// queue is resting.
    ///
    /// A job that is `queued` is waiting, and on this phone waiting has no deadline:
    /// nothing in this class fails a record because its job has been queued for a
    /// long time, whether behind fifty others or behind half an hour of cooldown.
    /// What a long wait needs is an explanation, and only /health has it.
    ///
    /// It is asked on two events, never on a schedule of its own. A job of this
    /// phone's has just failed while others are still queued — the bot wall fails
    /// exactly one job and rests the rest — or the polls have shown jobs queued and
    /// nothing running for longer than the gap the server leaves between two
    /// downloads. Either way at most once per `cooldownCheckInterval` unless a job
    /// has just failed, and not at all while an answer already says when the queue
    /// starts again. The poll itself already exists and already runs only while
    /// something is waiting on the server, in the foreground; this adds no timer.
    private func considerCooldown(jobs: [ServerJob], jobFailed: Bool) {
        let now = Date()
        if let until = serverCooldownUntil, until <= now {
            forgetCooldown()
        }
        let anyRunning = jobs.contains { $0.knownState == .running }
        let anyWaiting = activeRecords().contains {
            $0.stage == .onServer && $0.serverJobState == ServerJob.State.queued.rawValue
        }
        guard anyWaiting, !anyRunning else {
            queueIdleSince = nil
            if anyRunning {
                // The queue is moving, whatever it said before.
                forgetCooldown()
            }
            return
        }
        let idleSince = queueIdleSince ?? now
        queueIdleSince = idleSince
        guard serverCooldownUntil == nil else { return }
        if jobFailed {
            askWhetherQueueIsResting(force: true)
        } else if now.timeIntervalSince(idleSince) >= Self.queueIdleBeforeAsking {
            askWhetherQueueIsResting(force: false)
        }
    }

    /// One GET /health, off the loop: the loop goes on polling while it is out, and
    /// a failure here changes nothing — if the server is not answering, the poll is
    /// what says so.
    private func askWhetherQueueIsResting(force: Bool) {
        guard cooldownCheck == nil else { return }
        if !force, let asked = cooldownAskedAt,
           Date().timeIntervalSince(asked) < Self.cooldownCheckInterval {
            return
        }
        let client: APIClient
        do {
            client = try settings.makeClient()
        } catch {
            return
        }
        cooldownAskedAt = Date()
        cooldownCheck = Task { [weak self] in
            var until: Date?
            var answered = false
            do {
                let health = try await client.health()
                until = health.value.downloadCooldownEnd
                answered = true
            } catch {
                answered = false
            }
            guard let self else { return }
            self.cooldownCheck = nil
            if answered, self.serverCooldownUntil != until {
                self.serverCooldownUntil = until
            }
        }
    }

    /// The only state left over once nothing is pending.
    private func forgetWaiting() {
        if pollFailures != 0 {
            pollFailures = 0
        }
        if unreachableNotice != nil {
            unreachableNotice = nil
        }
    }

    /// Written only when it changes: every write wakes the rows that read it, and
    /// this is reached on every poll.
    private func forgetCooldown() {
        if serverCooldownUntil != nil {
            serverCooldownUntil = nil
        }
    }

    /// A library sync, then each record whose track has arrived moves on: to the
    /// device download for Telefono and Entrambi, and nowhere for Server, whose
    /// chain is finished the moment the track is in the catalogue.
    private func syncPending(generation: Int) async {
        // Joins a sync already running. If that one started before the track
        // existed, the next pass syncs again (see syncAttempts).
        await sync.refresh()
        guard generation == foregroundGeneration else { return }

        var unreachable: APIError?
        for record in activeRecords() where record.stage == .syncing {
            // Server needs no hash: nothing on this phone will verify a file it is
            // never going to receive.
            let needsHash = record.destination.downloadsToPhone
            if let track = storedTrack(record.videoID), !needsHash || track.sha256 != nil {
                if needsHash {
                    record.handoffRequestedAt = nil
                    record.stage = .handingOff
                } else {
                    finish(record)
                }
                continue
            }
            if case .failed(let error) = sync.status {
                if Self.isUnreachable(error) {
                    // The sync reached nobody. The track is on the server and the
                    // record is still `syncing`; it is synced again when the
                    // server is back, and this pass is not counted against it.
                    unreachable = error
                } else {
                    fail(record, .syncFailed, error, saving: false)
                }
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
        if let unreachable {
            serverDidNotAnswer(unreachable)
        } else {
            serverAnswered()
        }
    }

    /// Hands each track now in the library to the existing device download.
    ///
    /// Entrambi is finished as soon as the download owns the track: from there the
    /// track's own row reports it. Telefono is not, because it still has to delete
    /// the server's copy, and it may do that only once this phone holds a verified
    /// file - so it waits for `downloaded`, and a device download that fails leaves
    /// the server's copy exactly where it is.
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
            if requestedHere, let refusal = downloads.refusals[id], Self.isUnreachable(refusal) {
                // Refused for want of a server address, before anything was tried:
                // there is nobody to download from, which is waiting, not failing.
                // The track is as it was, so asking again later is the first
                // attempt, not a second one.
                handoffsThisProcess.remove(record.videoID)
                record.handoffRequestedAt = nil
                changed = true
                serverDidNotAnswer(refusal)
                break
            }
            if requestedHere, let refusal = downloads.refusals[id] {
                handoffsThisProcess.remove(record.videoID)
                fail(record, .deviceDownloadRefused, refusal, saving: false)
                changed = true
                continue
            }
            let changedSinceRequest = record.handoffRequestedAt.map { (track.stateChangedAt ?? .distantPast) >= $0 } ?? false

            switch track.downloadState {
            case .downloaded:
                if record.destination == .phone && track.serverDroppedAt == nil {
                    // The file is here and its SHA-256 matched. Only now.
                    handoffsThisProcess.remove(record.videoID)
                    record.deletionAttempts = 0
                    record.stage = .deletingFromServer
                } else {
                    finish(record)
                }
                changed = true
            case .queued, .downloading:
                if record.destination == .phone {
                    // Still arriving: the server keeps its copy until it has landed
                    // and verified. Nothing to record, so nothing is saved.
                    continue
                }
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

    /// Deletes the server's copy of every track whose phone copy is downloaded and
    /// verified, one at a time.
    private func deleteServerCopies(generation: Int) async {
        for videoID in activeRecords().filter({ $0.stage == .deletingFromServer }).map(\.videoID) {
            await deleteServerCopy(videoID, generation: generation)
            guard generation == foregroundGeneration else { return }
            if unanswered { return }
        }
    }

    /// The last step of Telefono, and the only place in the app that deletes a
    /// track the user still wants.
    ///
    /// Two things make it safe. First, it refuses to run unless the track is
    /// `downloaded` right now - the state `DownloadFinalizer` sets only after the
    /// received file's SHA-256 matched the server's - so a failed or unfinished
    /// device download can never reach the DELETE, and the server's copy simply
    /// stays. Second, `phoneOnlySince` is written and **saved before** the request
    /// goes out, because the server answers, then reports the id in the next
    /// delta's `deleted_track_ids`, and `LibrarySync` has to already know that this
    /// deletion was asked for here; a claim written afterwards would race the sync
    /// that discards the file.
    ///
    /// A claim left on a track whose DELETE did not succeed is harmless - the
    /// server still lists the track, so no deletion is ever reported for it - but a
    /// terminal failure withdraws it anyway, so the flag never outlives its reason.
    private func deleteServerCopy(_ videoID: String, generation: Int) async {
        guard let record = pendingRecord(videoID), record.stage == .deletingFromServer else { return }
        let name = record.title ?? videoID

        guard let track = storedTrack(videoID), track.downloadState == .downloaded else {
            // The file left the phone while this was waiting, e.g. Rimuovi dal
            // telefono. There is nothing to take ownership of, so the server keeps
            // its copy and the track stays available there.
            storedTrack(videoID)?.phoneOnlySince = nil
            finish(record)
            save("leaving the server's copy of “\(name)” in place")
            return
        }

        let client: APIClient
        do {
            client = try settings.makeClient()
        } catch {
            serverDidNotAnswer(.from(error))
            return
        }

        if track.phoneOnlySince == nil {
            track.phoneOnlySince = Date()
        }
        record.deletionAttempts += 1
        guard save("claiming the only copy of “\(name)”") else { return }

        do {
            _ = try await client.deleteTrack(trackID: videoID)
        } catch {
            guard generation == foregroundGeneration,
                  let current = pendingRecord(videoID), current.stage == .deletingFromServer else { return }
            let apiError = APIError.from(error)
            if Self.isUnreachable(apiError) {
                // Nobody answered, so nothing is known and nothing is counted. The
                // claim stays, on purpose: if the request did arrive, the deletion
                // it caused is one this phone asked for, and the next attempt hears
                // 404 and finishes. The verified file is on the phone throughout.
                current.deletionAttempts = max(0, current.deletionAttempts - 1)
                save("recording that the deletion request for “\(name)” got no answer")
                serverDidNotAnswer(apiError)
                return
            }
            serverAnswered()
            if apiError.httpStatus == 404 {
                // The server does not have it, which is where this step was going.
                finish(current)
                save("recording that the server no longer has “\(name)”")
                return
            }
            if apiError.httpStatus == 409, current.deletionAttempts < Self.maxDeletionAttempts {
                // Busy downloading this track, or writing the library. Ask again.
                return
            }
            // Terminal. The server still has its copy, so the claim is withdrawn:
            // nothing on this phone depends on it any more, and a deletion the
            // server makes later for its own reasons must behave normally again.
            storedTrack(videoID)?.phoneOnlySince = nil
            fail(current, .serverDeletionFailed, apiError)
            return
        }

        serverAnswered()
        guard let done = pendingRecord(videoID) else { return }
        finish(done)
        save("recording that the server deleted its copy of “\(name)”")
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

    // MARK: - Answered, or not

    /// Did this request reach nobody, as opposed to being answered?
    ///
    /// The one place that decides it, for every step of the chain.
    ///
    /// Nobody: a transport failure of any kind — timed out, could not connect, no
    /// network, name not found, connection lost — and a request that was cancelled
    /// under way. Also no usable address: with none saved there is no one to ask,
    /// so waiting is the honest state, and the notice says what is missing.
    ///
    /// Also a 5xx. It is an answer in the narrow sense, but what it says is that the
    /// server could not deal with the request just now — it is restarting, its
    /// proxy has no backend, its database is busy — and nothing about the track. It
    /// is exactly as temporary as a timeout, so it is treated as one.
    ///
    /// Everything else is an answer and may fail a record: a 4xx, a body that
    /// cannot be decoded, a job reported failed or cancelled, a job the server no
    /// longer lists after being asked again.
    static func isUnreachable(_ error: APIError) -> Bool {
        switch error.kind {
        case .transport, .cancelled, .notConfigured, .invalidAddress:
            return true
        case .http:
            return (error.httpStatus ?? 0) >= 500
        case .invalidInput, .invalidResponse, .decoding, .notAnImage, .storage, .verification, .unexpected:
            return false
        }
    }

    /// A request of the pass in progress reached nobody.
    ///
    /// Nothing is failed and nothing is moved. The pass is told to send no more,
    /// the notice goes up in place of an error, and `ServerReachability` is asked to
    /// look for itself — which is what turns its answer to "unreachable", so that
    /// the server coming back later is a change, and arrives as an event.
    private func serverDidNotAnswer(_ error: APIError) {
        unanswered = true
        pollFailures += 1
        var notice = error
        notice.message = "Il server non è raggiungibile, quindi i download in attesa sono fermi dove erano: non è fallito nulla, e ripartono da soli quando il server torna. "
            + PlainLanguage.message(for: error)
        unreachableNotice = notice
        reachability.retry()
    }

    /// The server answered something, whatever it was: it is there. The waiting
    /// state ends, and the notice that said it was away is withdrawn with it.
    private func serverAnswered() {
        if pollFailures != 0 {
            pollFailures = 0
        }
        if unreachableNotice != nil {
            unreachableNotice = nil
        }
    }

    /// The outcome of a job that ended without this phone watching, recorded as the
    /// poll would have recorded it.
    private func failForEndedJob(_ record: PendingAcquisition, _ job: ServerJob, url: String) {
        record.jobID = job.id
        record.serverJobState = job.state
        record.serverProgress = job.progress
        record.serverError = job.error
        if job.knownState == .cancelled {
            fail(record, .serverCancelled, APIError(
                kind: .unexpected,
                title: "The download was cancelled on the server",
                url: url,
                details: ["Job \(job.id) for \(record.videoID) is cancelled."]
            ), saving: false)
        } else {
            fail(record, .serverDownloadFailed, APIError(
                kind: .unexpected,
                title: "The server could not download the track",
                url: url,
                details: ["Job \(job.id) for \(record.videoID) failed.", "Server error: \(job.error ?? "(none given)")"],
                message: Self.serverFailureMessage(job.error)
            ), saving: false)
        }
    }

    /// The newest job for the video that ended in failure or was cancelled, among
    /// those created no earlier than the request this phone sent at `sentAt`.
    ///
    /// The server's clock dates the job and this phone's dated the request, so a
    /// few seconds are allowed between them. A job older than that belongs to an
    /// earlier request — typically the failure the user has just tapped Riprova on —
    /// and says nothing about this one.
    static func newestEndedJob(for videoID: String, in jobs: [ServerJob], since sentAt: Date) -> ServerJob? {
        let earliest = sentAt.timeIntervalSince1970 - clockSkewAllowance
        return jobs
            .filter { job in
                guard job.trackID == videoID, Double(job.createdAt) >= earliest else { return false }
                switch job.knownState {
                case .failed, .cancelled: return true
                case .queued, .running, .done, nil: return false
                }
            }
            .max { $0.id < $1.id }
    }

    /// The newest job for the video that is still going or finished.
    ///
    /// `since`, when given, leaves out jobs that finished for a request older than
    /// the one this phone sent then: the full list of jobs reaches back to earlier
    /// downloads of the same track, and a job done long ago says nothing about a
    /// track asked for again. A job still queued or running is worth adopting
    /// whoever asked for it.
    static func newestLiveJob(for videoID: String, in jobs: [ServerJob], since sentAt: Date? = nil) -> ServerJob? {
        let earliest = sentAt.map { $0.timeIntervalSince1970 - clockSkewAllowance }
        return jobs
            .filter { job in
                guard job.trackID == videoID else { return false }
                switch job.knownState {
                case .queued, .running: return true
                case .done: return earliest.map { Double(job.createdAt) >= $0 } ?? true
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
            return error.message ?? serverFailureMessage(nil)
        case .serverCancelled:
            return "Il download è stato annullato sul server. Tocca Riprova per richiederlo di nuovo."
        case .serverLostJob:
            return "Il server ha perso traccia della richiesta, forse perché è stato riavviato o reinstallato. Tocca Riprova."
        case .syncFailed:
            return "Il brano è sul server, ma la sincronizzazione della libreria non è riuscita: "
                + PlainLanguage.message(for: error).lowercasedFirst + " Poi tocca Riprova."
        case .notInLibrary:
            return "Il server dice di avere il brano, ma non compare nella libreria. Prova Risincronizza tutto in Libreria, poi tocca Riprova."
        case .serverDeletionFailed:
            return "Il brano è stato scaricato e verificato su questo telefono, ma il server non ha eliminato la sua copia, quindi ora sta su entrambi: non si è perso nulla. Tocca Riprova per liberare lo spazio sul server."
        case .deviceDownloadRefused:
            return "Il brano è in libreria, ma il download sul telefono non è partito: "
                + PlainLanguage.message(for: error).lowercasedFirst + " Poi tocca Riprova."
        case .storage:
            return "Non è stato possibile salvare sul telefono. Controlla lo spazio libero, poi tocca Riprova."
        case .unexpected:
            return "Errore imprevisto durante la richiesta al server. Tocca Riprova; se si ripete, riavvia l'app."
        }
    }

    /// The server's job error, reduced to a cause. Recognises the failures the backend
    /// and yt-dlp report in a stable form; anything else gets the general sentence.
    static func serverFailureMessage(_ serverError: String?) -> String {
        let text = (serverError ?? "").lowercased()
        if text.contains("interrupted by a backend restart") {
            return "Il server è stato riavviato mentre scaricava il brano, quindi il download si è interrotto. Tocca Riprova."
        }
        if text.contains("sign in to confirm") || text.contains("confirm you") {
            return "YouTube ha bloccato il server chiedendo di confermare che non è un bot. Riprova più tardi; se continua, yt-dlp sul server va aggiornato."
        }
        if text.contains("video unavailable") || text.contains("not available") || text.contains("private video") {
            return "Il video non è disponibile su YouTube, per esempio perché è privato o rimosso. Cerca un'altra versione del brano."
        }
        return "Il server non è riuscito a scaricare il brano da YouTube. Riprova più tardi; se succede con ogni brano, yt-dlp sul server va aggiornato."
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

    /// The other place where `isDeleted` still means something: a fetch made
    /// between this coordinator's own `context.delete` and its save still lists the
    /// record, and here that genuinely is "deleted, not yet saved". Everywhere a
    /// deletion could already have been saved, the question is asked of the store
    /// instead (`ModelLookup`).
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
