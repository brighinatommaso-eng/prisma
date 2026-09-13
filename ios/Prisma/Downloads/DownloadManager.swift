import Foundation
import Observation
import SwiftData

/// Owns the app's single background URLSession and every change to download state.
///
/// Created once per process by `AppModel`, at launch, including a launch in the
/// background to deliver finished transfers. It is never owned by a view: a
/// background session has one delegate for the app's lifetime, and events that
/// arrive while no view exists must still be recorded.
@Observable
final class DownloadManager {
    nonisolated static let sessionIdentifier = "com.brighina.prisma.downloads"
    /// A transfer that cannot finish within this is failed by iOS with a timeout
    /// instead of waiting indefinitely, e.g. while the server is unreachable.
    nonisolated static let transferTimeout: TimeInterval = 30 * 60
    /// Space left free after a queued download completes.
    static let reserveBytes = 50 * 1024 * 1024
    /// A queued attempt that has received no data after this long is failed as
    /// "never started". Background sessions retry refused or timed-out connections
    /// without reporting them, so without a limit a wrong address waits forever.
    nonisolated static let startDeadline: TimeInterval = 120

    struct Progress {
        let received: Int64
        let expected: Int64
    }

    struct Notice: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    /// Live progress by download token. Not persisted: after a relaunch it
    /// reappears with the next progress callback.
    private(set) var progress: [String: Progress] = [:]
    /// Why the last Download/Cancel/Remove tap on a track was refused, by track id.
    private(set) var refusals: [String: APIError] = [:]
    /// Things that happened outside any one track's row: store save failures,
    /// automatic restarts, stray-file cleanup.
    private(set) var notices: [Notice] = []
    private(set) var liveTransferCount: Int?
    private(set) var lastCheck: Date?
    private(set) var isChecking = false
    /// Tracks whose pre-flight check is running or pending, with when it began.
    /// The transfer check and the start deadline leave these alone.
    private(set) var preflights: [String: Date] = [:]

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var eventsDeliveredBeforeHandler = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?

    init(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings

        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = Self.transferTimeout
        configuration.httpMaximumConnectionsPerHost = 2

        let queue = OperationQueue()
        queue.name = "Prisma download delegate"
        queue.maxConcurrentOperationCount = 1

        // DispatchQueue.main.async keeps events in the order the delegate produced
        // them, so a late progress tick can never land after its completion.
        let delegate = DownloadSessionDelegate { [self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.handle(event)
                }
            }
        }
        // Creating the session reconnects to transfers iOS kept running while the
        // app was not, and starts delivering their pending events.
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    // MARK: - Actions from the UI

    func download(_ track: StoredTrack) {
        refusals[track.serverID] = nil
        guard preflights[track.serverID] == nil else {
            refusals[track.serverID] = .invalidInput("Already checking", detail: "The pre-flight check for this track is still running.")
            return
        }
        switch track.downloadState {
        case .notDownloaded, .failed, .cancelled:
            Task {
                await enqueue(track, note: nil, keepQueuePosition: false, failureLead: nil)
            }
        case .queued, .downloading, .downloaded:
            refusals[track.serverID] = .invalidInput("Nothing to do", detail: "This track is already \(track.downloadState.label.lowercased()).")
        }
    }

    func cancel(_ track: StoredTrack) {
        refusals[track.serverID] = nil
        guard track.downloadState == .queued || track.downloadState == .downloading else {
            refusals[track.serverID] = .invalidInput("Nothing to cancel", detail: "This track is \(track.downloadState.label.lowercased()).")
            return
        }
        let token = track.downloadToken
        if let token { progress[token] = nil }
        track.downloadToken = nil
        track.taskIdentifier = nil
        track.resumeData = nil
        track.errorText = nil
        track.note = "Cancelled at \(Formatting.time(Date()))."
        track.downloadState = .cancelled
        save("cancelling a download")
        if let token { cancelTransfer(token: token) }
    }

    func dismiss(_ track: StoredTrack) {
        refusals[track.serverID] = nil
        guard track.downloadState == .failed || track.downloadState == .cancelled else {
            refusals[track.serverID] = .invalidInput("Nothing to dismiss", detail: "This track is \(track.downloadState.label.lowercased()).")
            return
        }
        track.errorText = nil
        track.note = nil
        track.resumeData = nil
        track.downloadState = .notDownloaded
        save("dismissing a download")
    }

    /// Deletes the audio file and keeps the catalogue row.
    func removeFile(_ track: StoredTrack) {
        refusals[track.serverID] = nil
        guard track.downloadState == .downloaded else {
            refusals[track.serverID] = .invalidInput("Nothing to remove", detail: "This track is \(track.downloadState.label.lowercased()).")
            return
        }
        if let fileName = track.fileName {
            do {
                try LocalFiles.removeIfPresent(try LocalFiles.url(.music, fileName))
            } catch {
                refusals[track.serverID] = .storage("Could not delete the audio file", location: nil, error: error)
                return
            }
        }
        track.fileName = nil
        track.storedBytes = nil
        track.note = "Removed from this iPhone at \(Formatting.time(Date()))."
        track.downloadState = .notDownloaded
        save("removing a downloaded file")
    }

    func clearNotices() {
        notices.removeAll()
    }

    // MARK: - Used by LibrarySync

    /// Before a track row is deleted: stop its transfer and delete its files.
    /// Returns a problem description if a file could not be deleted.
    func discardLocalData(for track: StoredTrack) -> String? {
        if let token = track.downloadToken {
            progress[token] = nil
            cancelTransfer(token: token)
        }
        track.resumeData = nil
        guard let fileName = track.fileName else { return nil }
        do {
            try LocalFiles.removeIfPresent(try LocalFiles.url(.music, fileName))
            return nil
        } catch {
            return "Could not delete \(fileName) for removed track \(track.serverID): \(error.localizedDescription)"
        }
    }

    /// The server's file for this track has a new SHA-256: whatever is local is stale.
    func serverFileChanged(for track: StoredTrack) {
        switch track.downloadState {
        case .downloaded:
            if let problem = discardLocalData(for: track) {
                notice(problem)
            }
            track.fileName = nil
            track.storedBytes = nil
            track.note = "The server's copy of this track changed, so the old file was removed. Download it again."
            track.downloadState = .notDownloaded
        case .queued, .downloading:
            if let token = track.downloadToken {
                progress[token] = nil
                cancelTransfer(token: token)
            }
            track.downloadToken = nil
            track.taskIdentifier = nil
            track.resumeData = nil
            track.errorText = "The server's copy of this track changed while it was downloading, so the transfer was stopped. Retry to download the new file."
            track.downloadState = .failed
        case .failed, .cancelled:
            // Resume data refers to the old file and must not be continued.
            track.resumeData = nil
        case .notDownloaded:
            break
        }
    }

    // MARK: - Background launch

    /// Called by the app delegate when iOS launches or wakes the app for this session.
    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else {
            notice("iOS delivered events for an unknown background session \"\(identifier)\"; ignored.")
            completionHandler()
            return
        }
        if eventsDeliveredBeforeHandler {
            eventsDeliveredBeforeHandler = false
            save("recording background transfer results")
            completionHandler()
        } else {
            backgroundCompletion = completionHandler
        }
    }

    // MARK: - Transfer check

    /// Makes the store agree with what iOS is actually doing.
    ///
    /// After a relaunch, a track can be `queued` or `downloading` with no transfer
    /// behind it (for example the app was force-quit, which cancels background
    /// transfers). This restarts those, recovers verified files left by
    /// interrupted transfers, marks downloaded tracks whose file is gone, and
    /// deletes files nothing refers to.
    func checkTransfers(reason: String) {
        guard !isChecking else { return }
        guard let session else {
            notice("Transfer check skipped: the background session does not exist.")
            return
        }
        isChecking = true
        Task {
            // Let iOS deliver events for transfers that finished while the app was
            // not running, so they are recorded rather than restarted.
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                notice("Transfer check was interrupted: \(error.localizedDescription)")
                isChecking = false
                return
            }
            let tasks = await session.allTasks
            let toRestart = runCheck(tasks: tasks, reason: reason)
            isChecking = false
            for track in toRestart {
                preflights[track.serverID] = nil
                let resuming = track.resumeData != nil && track.targetAddress == settings.savedAddress
                await enqueue(
                    track,
                    note: "Restarted automatically (\(reason)): iOS no longer had a transfer for it"
                        + (resuming ? ", resuming from where it stopped." : ", starting from the beginning."),
                    keepQueuePosition: true,
                    failureLead: "Its transfer was lost (\(reason)) and could not be restarted."
                )
            }
            ensureWatchdog()
        }
    }

    /// Returns the tracks whose transfer was lost, to be restarted after this returns.
    private func runCheck(tasks: [URLSessionTask], reason: String) -> [StoredTrack] {
        let live = tasks.filter { $0.state == .running || $0.state == .suspended }
        for task in live where task.state == .suspended {
            task.resume()
        }
        liveTransferCount = live.count
        lastCheck = Date()
        let liveTokens = Set(live.compactMap { task -> String? in
            guard case .success(let descriptor) = DownloadTaskDescriptor.decode(task.taskDescription) else { return nil }
            return descriptor.token
        })

        let tracks: [StoredTrack]
        do {
            tracks = try context.fetch(FetchDescriptor<StoredTrack>())
        } catch {
            notice("Transfer check could not read the local library: \(error.localizedDescription)")
            return []
        }

        let recovered = recoverAndCleanMusicFiles(tracks: tracks)

        var toRestart: [StoredTrack] = []
        for track in tracks where track.downloadState == .queued || track.downloadState == .downloading {
            if preflights[track.serverID] != nil { continue }
            if let token = track.downloadToken, liveTokens.contains(token) { continue }
            // Changed in the last few seconds: its completion event may still be on the way.
            if let changed = track.stateChangedAt, Date().timeIntervalSince(changed) < 5 { continue }
            track.downloadToken = nil
            track.taskIdentifier = nil
            // Held until the restart's own pre-flight begins, so nothing else touches it.
            preflights[track.serverID] = Date()
            toRestart.append(track)
        }
        toRestart.sort { ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast) }
        let restarted = toRestart.count

        var missing = 0
        for track in tracks where track.downloadState == .downloaded {
            let present: Bool
            if let fileName = track.fileName {
                do {
                    present = LocalFiles.exists(try LocalFiles.url(.music, fileName))
                } catch {
                    notice("Could not check the file of \(track.title ?? track.serverID): \(error.localizedDescription)")
                    continue
                }
            } else {
                present = false
            }
            if !present {
                track.fileName = nil
                track.storedBytes = nil
                track.errorText = "The track was marked downloaded, but its audio file is no longer on this iPhone. Retry to download it again."
                track.downloadState = .failed
                missing += 1
            }
        }

        var summary: [String] = []
        if restarted > 0 { summary.append("restarting \(restarted) lost transfer(s), each after a pre-flight check") }
        if recovered.adopted > 0 { summary.append("recovered \(recovered.adopted) verified file(s) from interrupted transfers") }
        if recovered.removed > 0 { summary.append("deleted \(recovered.removed) stray file(s)") }
        if missing > 0 { summary.append("\(missing) downloaded track(s) had lost their file and were marked failed") }
        if !summary.isEmpty {
            notice("Transfer check (\(reason)): " + summary.joined(separator: "; ") + ".")
        }
        save("recording the transfer check")
        return toRestart
    }

    /// Adopts verified files an interrupted transfer finished writing, and deletes
    /// files and partials that no track refers to.
    private func recoverAndCleanMusicFiles(tracks: [StoredTrack]) -> (adopted: Int, removed: Int) {
        let files: [URL]
        do {
            files = try LocalFiles.contents(of: .music)
        } catch {
            notice("Could not list the Music folder: \(error.localizedDescription)")
            return (0, 0)
        }
        var referenced = Set<String>()
        var byFileName: [String: StoredTrack] = [:]
        for track in tracks {
            if track.downloadState == .downloaded, let fileName = track.fileName {
                referenced.insert(fileName)
            }
            byFileName[LocalFiles.musicFileName(trackID: track.serverID)] = track
        }

        var adopted = 0
        var removed = 0
        for file in files {
            let name = file.lastPathComponent
            if referenced.contains(name) { continue }
            // The delegate may be writing this file right now on its own queue.
            do {
                if let modified = try LocalFiles.modificationDate(file), Date().timeIntervalSince(modified) < 60 { continue }
            } catch {
                notice("Could not read the date of \(name): \(error.localizedDescription)")
                continue
            }

            if !name.hasSuffix(".partial"), let track = byFileName[name],
               [.queued, .downloading, .failed].contains(track.downloadState),
               let expected = track.sha256?.lowercased() {
                do {
                    if try LocalFiles.sha256Hex(of: file) == expected {
                        if let token = track.downloadToken {
                            progress[token] = nil
                            cancelTransfer(token: token)
                        }
                        track.downloadToken = nil
                        track.taskIdentifier = nil
                        track.resumeData = nil
                        track.errorText = nil
                        track.fileName = name
                        track.storedBytes = try LocalFiles.fileSize(file)
                        track.note = "Recovered a verified file left by an interrupted transfer."
                        track.downloadState = .downloaded
                        referenced.insert(name)
                        adopted += 1
                        continue
                    }
                } catch {
                    notice("Could not verify leftover file \(name): \(error.localizedDescription). It will be deleted.")
                }
            }

            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
            } catch {
                notice("Could not delete stray file \(name): \(error.localizedDescription)")
            }
        }
        return (adopted, removed)
    }

    // MARK: - Starting and cancelling transfers

    private struct Prepared {
        let client: APIClient
        let address: String
        let sha: String
        let bytes: Int
    }

    /// Checks that need no network: session, hash, size, address, free space.
    private func prepare(_ track: StoredTrack) throws -> Prepared {
        guard session != nil else {
            throw APIError.invalidInput("Downloads unavailable", detail: "The background download session was not created.")
        }
        guard let sha = track.sha256?.lowercased(), sha.count == 64 else {
            throw APIError.invalidInput(
                "Cannot verify this track",
                detail: "The server gave no valid SHA-256 for track \(track.serverID) (got \"\(track.sha256 ?? "nothing")\"), so a download could not be checked. Sync the library and try again."
            )
        }
        guard let bytes = track.fileBytes, bytes > 0 else {
            throw APIError.invalidInput(
                "Unknown file size",
                detail: "The server gave no file size for track \(track.serverID), so free space cannot be checked. Sync the library and try again."
            )
        }
        let client = try settings.makeClient()
        try checkFreeSpace(for: track, bytes: bytes)
        return Prepared(client: client, address: settings.savedAddress, sha: sha, bytes: bytes)
    }

    /// Every download goes through here: local checks, then a pre-flight request
    /// over the foreground session, then the background task.
    ///
    /// A failed pre-flight marks the track failed straight away with the full
    /// error, instead of handing iOS a transfer it would retry silently.
    /// `failureLead` explains an automatic restart that could not be done.
    /// Returns the error when the pre-flight could not reach the server at all, so
    /// a batch can stop probing an address that is not there.
    @discardableResult
    private func enqueue(_ track: StoredTrack, note: String?, keepQueuePosition: Bool, failureLead: String?) async -> APIError? {
        let trackID = track.serverID
        let stateBefore = track.downloadState
        let isAutomatic = stateBefore == .queued || stateBefore == .downloading

        let prepared: Prepared
        do {
            prepared = try prepare(track)
        } catch {
            let apiError = APIError.from(error)
            if isAutomatic {
                failTrack(track, error: apiError, lead: failureLead)
            } else {
                // Nothing was attempted: refuse and leave the track as it was.
                refusals[trackID] = apiError
            }
            return nil
        }

        preflights[trackID] = Date()
        let probe: TrackFileProbe
        do {
            probe = try await prepared.client.probeTrackFile(trackID: trackID)
        } catch {
            preflights[trackID] = nil
            let apiError = APIError.from(error)
            guard !track.isDeleted, track.downloadState == stateBefore else { return nil }
            failTrack(
                track,
                error: apiError,
                lead: (failureLead.map { $0 + " " } ?? "")
                    + "Pre-flight check failed: the server did not serve this track's file, so no transfer was queued."
            )
            return apiError.kind == .transport ? apiError : nil
        }
        preflights[trackID] = nil
        // Removed by a sync, or cancelled, while the check was running.
        guard !track.isDeleted, track.downloadState == stateBefore else { return nil }

        do {
            try handToSession(track, prepared: prepared, probe: probe, note: note, keepQueuePosition: keepQueuePosition)
        } catch {
            failTrack(track, error: .from(error), lead: failureLead)
        }
        return nil
    }

    private func handToSession(
        _ track: StoredTrack,
        prepared: Prepared,
        probe: TrackFileProbe,
        note: String?,
        keepQueuePosition: Bool
    ) throws {
        guard let session else {
            throw APIError.invalidInput("Downloads unavailable", detail: "The background download session was not created.")
        }
        let token = UUID().uuidString
        let description = try DownloadTaskDescriptor(
            version: 1, trackID: track.serverID, token: token, sha256: prepared.sha, fileBytes: prepared.bytes
        ).encoded()

        let task: URLSessionDownloadTask
        // Resume data embeds the URL of the attempt that produced it, so it is only
        // continued against the same address. Otherwise the download starts fresh.
        if let resumeData = track.resumeData, track.targetAddress == prepared.address {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: probe.url)
            request.setValue("audio/*", forHTTPHeaderField: "Accept")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = description

        // Consumed: if this attempt fails, its own resume data replaces it.
        track.resumeData = nil
        track.downloadToken = token
        track.taskIdentifier = task.taskIdentifier
        if !keepQueuePosition || track.queuedAt == nil {
            track.queuedAt = Date()
        }
        track.attemptStartedAt = Date()
        track.targetAddress = prepared.address
        track.preflightSummary = probe.summary
        track.lastSessionError = nil
        track.errorText = nil
        track.note = note
        track.downloadState = .queued
        save("queueing a download")
        task.resume()
        ensureWatchdog()
    }

    /// Stores an error in the same shape as `APIError.fullText` (title first), so
    /// the row renders it like every other error in the app.
    private func failTrack(_ track: StoredTrack, error: APIError, lead: String?) {
        if let token = track.downloadToken {
            progress[token] = nil
        }
        track.downloadToken = nil
        track.taskIdentifier = nil
        track.preflightSummary = nil
        track.errorText = error.title + "\n" + (lead.map { $0 + "\n" } ?? "") + error.detailText
        track.downloadState = .failed
        save("recording a failed download")
    }

    // MARK: - Server address changes

    /// Called when a different server address is saved in Settings.
    ///
    /// Queued transfers were built against the old address and would keep
    /// retrying it, so they are stopped and queued again, in their original order,
    /// each after a pre-flight check against the new address.
    ///
    /// Transfers already receiving data are left to finish: data arriving proves
    /// the old address reaches the server, every file is checked against its
    /// SHA-256 whichever address served it, and restarting would throw the
    /// progress away. If one later fails, Retry uses the new address.
    func serverAddressChanged(from previous: String, to new: String) {
        guard !previous.isEmpty else { return }
        Task {
            await retarget(from: previous, to: new)
        }
    }

    private func retarget(from previous: String, to new: String) async {
        let tracks: [StoredTrack]
        do {
            tracks = try context.fetch(FetchDescriptor<StoredTrack>())
        } catch {
            notice("The server address changed, but queued downloads could not be read to re-target them: \(error.localizedDescription)")
            return
        }

        var discardedResume = 0
        for track in tracks where (track.downloadState == .failed || track.downloadState == .cancelled)
            && track.resumeData != nil && track.targetAddress != new {
            track.resumeData = nil
            discardedResume += 1
        }

        let queued = tracks
            .filter { $0.downloadState == .queued && $0.targetAddress != new && preflights[$0.serverID] == nil }
            .sorted { ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast) }
        let running = tracks.filter { $0.downloadState == .downloading && $0.targetAddress != new }

        // Stop every old transfer before checking any, so none keeps retrying the
        // old address while the others wait their turn.
        for track in queued {
            if let token = track.downloadToken {
                progress[token] = nil
                cancelTransfer(token: token)
            }
            track.downloadToken = nil
            track.taskIdentifier = nil
            track.resumeData = nil
            preflights[track.serverID] = Date()
        }
        save("stopping transfers built against the previous address")

        var started = 0
        var failed = 0
        var skipped = 0
        var unreachable: APIError?
        for track in queued {
            preflights[track.serverID] = nil
            guard !track.isDeleted, track.downloadState == .queued else {
                skipped += 1
                continue
            }
            if let unreachable {
                failTrack(
                    track,
                    error: unreachable,
                    lead: "Not checked separately: the pre-flight check for the previous track in the queue could not reach the server at \(new)."
                )
                failed += 1
                continue
            }
            unreachable = await enqueue(
                track,
                note: "Re-targeted to \(new) after the server address changed.",
                keepQueuePosition: true,
                failureLead: "The server address changed and this download could not be re-targeted."
            )
            if track.downloadState == .queued {
                started += 1
            } else {
                failed += 1
            }
        }

        var lines = ["Server address changed from \(previous) to \(new)."]
        if !queued.isEmpty {
            var line = "\(queued.count) queued download(s) re-targeted in their original order: \(started) queued again against the new address"
            if failed > 0 { line += ", \(failed) failed their pre-flight check (their rows show why)" }
            if skipped > 0 { line += ", \(skipped) skipped because they were cancelled or removed meanwhile" }
            lines.append(line + ".")
        }
        if !running.isEmpty {
            lines.append("\(running.count) running transfer(s) left to finish on the previous address: they were already receiving data, and each file is checked against its SHA-256 whichever address served it, so restarting would only discard progress. If one fails, Retry uses the new address.")
        }
        if discardedResume > 0 {
            lines.append("\(discardedResume) failed or cancelled download(s) had resume data for the previous address discarded; Retry starts them from the beginning.")
        }
        if queued.isEmpty && running.isEmpty && discardedResume == 0 {
            lines.append("No downloads were affected.")
        }
        notice(lines.joined(separator: "\n"))
        save("re-targeting downloads")
    }

    // MARK: - Start deadline

    private func ensureWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task {
            while await enforceStartDeadline() {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    notice("The check for downloads that never start stopped: \(error.localizedDescription)")
                    break
                }
            }
            watchdog = nil
        }
    }

    /// Fails queued attempts that received no data within `startDeadline`.
    /// Returns whether anything is still queued, i.e. whether to keep checking.
    private func enforceStartDeadline() async -> Bool {
        guard let session else { return false }
        // iOS's own byte counts, not progress events: a suspended app receives no
        // progress events, so a transfer that ran while the screen was locked would
        // otherwise look like one that never started.
        let tasks = await session.allTasks
        var tasksByToken: [String: URLSessionTask] = [:]
        for task in tasks {
            if case .success(let descriptor) = DownloadTaskDescriptor.decode(task.taskDescription) {
                tasksByToken[descriptor.token] = task
            }
        }

        let queued: [StoredTrack]
        do {
            queued = try context.fetch(FetchDescriptor<StoredTrack>()).filter { $0.downloadState == .queued }
        } catch {
            notice("Could not read queued downloads to check for ones that never started: \(error.localizedDescription)")
            return false
        }

        let now = Date()
        var neverStarted: [String] = []
        for track in queued {
            guard preflights[track.serverID] == nil, let started = track.attemptStartedAt else { continue }
            let task = track.downloadToken.flatMap { tasksByToken[$0] }
            if let task, task.countOfBytesReceived > 0 {
                track.downloadState = .downloading
                continue
            }
            guard now.timeIntervalSince(started) >= Self.startDeadline else { continue }

            task?.cancel()
            let minutes = Int(Self.startDeadline / 60)
            let target = track.targetAddress ?? settings.savedAddress
            let lastProblem = track.lastSessionError
                ?? "none. Background transfers retry refused or timed-out connections without reporting them, which is why this limit exists."
            let error = APIError(
                kind: .transport,
                title: "Download never started",
                url: task?.originalRequest?.url?.absoluteString,
                details: [
                    "Handed to iOS at \(Formatting.time(started)); no data had arrived after \(minutes) minutes, so the transfer was stopped.",
                    "Transfer state reported by iOS: \(task.map { Self.describe($0.state) } ?? "no transfer found")",
                    "Last problem reported by iOS: \(lastProblem)",
                    track.preflightSummary ?? "No pre-flight result was recorded for this attempt.",
                    "Hint: the server may not be reachable at \(target). Open Settings, check the address with Test connection, then tap Retry.",
                ]
            )
            failTrack(track, error: error, lead: nil)
            neverStarted.append(track.title ?? track.serverID)
        }
        if !neverStarted.isEmpty {
            notice("\(neverStarted.count) download(s) received no data within \(Int(Self.startDeadline / 60)) minutes and were marked failed: "
                + neverStarted.joined(separator: ", ") + ". Check the server address, then Retry.")
        }
        if context.hasChanges {
            save("checking for downloads that never started")
        }
        return queued.contains { $0.downloadState == .queued } || !preflights.isEmpty
    }

    private static func describe(_ state: URLSessionTask.State) -> String {
        switch state {
        case .running: return "running, 0 bytes received"
        case .suspended: return "suspended"
        case .canceling: return "cancelling"
        case .completed: return "completed without delivering a result yet"
        @unknown default: return "unknown (\(state.rawValue))"
        }
    }

    private func checkFreeSpace(for track: StoredTrack, bytes: Int) throws {
        let available: Int64
        do {
            available = try LocalFiles.availableCapacity()
        } catch {
            throw APIError.storage("Could not check free space before downloading", location: nil, error: error)
        }
        let pending: Int
        do {
            pending = try context.fetch(FetchDescriptor<StoredTrack>())
                .filter { $0.serverID != track.serverID && ($0.downloadState == .queued || $0.downloadState == .downloading) }
                .reduce(0) { $0 + ($1.fileBytes ?? 0) }
        } catch {
            throw APIError.storage("Could not read queued downloads to check free space", location: nil, error: error)
        }
        let needed = Int64(bytes + pending + Self.reserveBytes)
        guard available >= needed else {
            throw APIError(
                kind: .storage,
                title: "Not enough free space on this iPhone",
                url: nil,
                details: [
                    "This track: \(Formatting.bytes(bytes))",
                    "Already queued or downloading: \(Formatting.bytes(pending))",
                    "Kept free as a reserve: \(Formatting.bytes(Self.reserveBytes))",
                    "Needed: \(Formatting.bytes(Int(needed))), available: \(Formatting.bytes(Int(available)))",
                    "Free up space or remove downloaded tracks, then try again.",
                ]
            )
        }
    }

    private func cancelTransfer(token: String) {
        guard let session else { return }
        Task {
            for task in await session.allTasks {
                if case .success(let descriptor) = DownloadTaskDescriptor.decode(task.taskDescription),
                   descriptor.token == token {
                    task.cancel()
                }
            }
        }
    }

    // MARK: - Events from the delegate

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let trackID, let token, let received, let expected):
            progress[token] = Progress(received: received, expected: expected)
            guard let track = track(id: trackID), track.downloadToken == token, track.downloadState == .queued else { return }
            track.downloadState = .downloading
            save("marking a download as started")

        case .waitingForConnectivity(let trackID, let token, let at):
            guard let track = track(id: trackID), track.downloadToken == token else { return }
            track.lastSessionError = "At \(Formatting.time(at)) iOS reported this transfer is waiting for network connectivity."
            save("recording a connectivity wait")

        case .finished(let trackID, let token, let result):
            progress[token] = nil
            finish(trackID: trackID, token: token, result: result)

        case .unmatched(let taskIdentifier, let error):
            notice("A background transfer (task \(taskIdentifier)) could not be matched to a track and was ignored.\n\(error.fullText)")

        case .allEventsDelivered:
            save("recording background transfer results")
            if let completion = backgroundCompletion {
                backgroundCompletion = nil
                completion()
            } else {
                eventsDeliveredBeforeHandler = true
            }
        }
    }

    private func finish(trackID: String, token: String, result: TaskResult) {
        guard let track = track(id: trackID) else {
            if case .outcome(.verified(let fileName, _)) = result {
                deleteStray(fileName, because: "its track is no longer in the local library")
            }
            return
        }
        guard track.downloadToken == token else {
            finishSuperseded(track: track, result: result)
            return
        }

        track.downloadToken = nil
        track.taskIdentifier = nil
        switch result {
        case .outcome(.verified(let fileName, let bytes)):
            track.fileName = fileName
            track.storedBytes = bytes
            track.errorText = nil
            track.resumeData = nil
            track.downloadState = .downloaded

        case .outcome(.failed(let error)):
            track.errorText = error.fullText
            track.downloadState = .failed

        case .transportError(let error, let resumeData, let reason):
            track.resumeData = resumeData
            if error.isCancellation && reason == NSURLErrorCancelledReasonUserForceQuitApplication {
                // Force-quitting the app cancels its background transfers. That is
                // not the user asking to stop this download, so start it again,
                // through the pre-flight like any other enqueue.
                track.downloadState = .queued
                preflights[track.serverID] = Date()
                save("recording a transfer stopped by closing the app")
                Task {
                    preflights[track.serverID] = nil
                    await enqueue(
                        track,
                        note: "Restarted automatically: closing the app from the app switcher stopped the transfer"
                            + (resumeData != nil ? ". Resuming from where it stopped if the address is unchanged." : ". Starting from the beginning."),
                        keepQueuePosition: true,
                        failureLead: "The app was closed from the app switcher, which stopped the transfer, and it could not be restarted."
                    )
                }
                return
            } else {
                var text = error.fullText
                if let reason {
                    text += "\nCancelled by iOS: \(Self.describeCancelReason(reason))"
                }
                if resumeData != nil {
                    text += "\nRetry continues from where it stopped."
                }
                track.errorText = text
                track.downloadState = .failed
            }
        }
        save("recording a finished download")
    }

    /// An event from an earlier attempt than the track's current one.
    private func finishSuperseded(track: StoredTrack, result: TaskResult) {
        // Failures and cancellations of an older attempt are superseded by the
        // current state, which is already shown. Only a verified file matters.
        guard case .outcome(.verified(let fileName, let bytes)) = result else { return }
        switch track.downloadState {
        case .queued, .downloading:
            if let newer = track.downloadToken {
                progress[newer] = nil
                cancelTransfer(token: newer)
            }
            track.downloadToken = nil
            track.taskIdentifier = nil
            track.resumeData = nil
            track.errorText = nil
            track.fileName = fileName
            track.storedBytes = bytes
            track.note = "An earlier transfer finished and verified, so the newer one was stopped."
            track.downloadState = .downloaded
            save("recording an earlier transfer's file")
        case .downloaded:
            // Same file name, verified content: the file on disk is valid either way.
            break
        case .notDownloaded, .failed, .cancelled:
            deleteStray(fileName, because: "the track was cancelled or removed before the transfer finished")
        }
    }

    // MARK: - Helpers

    private func track(id: String) -> StoredTrack? {
        var descriptor = FetchDescriptor<StoredTrack>(predicate: #Predicate<StoredTrack> { $0.serverID == id })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            notice("Could not read track \(id) from the local library: \(error.localizedDescription)")
            return nil
        }
    }

    private func deleteStray(_ fileName: String, because reason: String) {
        do {
            try LocalFiles.removeIfPresent(try LocalFiles.url(.music, fileName))
        } catch {
            notice("Could not delete \(fileName), which is unused because \(reason): \(error.localizedDescription)")
        }
    }

    func save(_ activity: String) {
        do {
            try context.save()
        } catch {
            notice("Saving the local library failed while \(activity): \(error.localizedDescription)\n\(String(describing: error))")
        }
    }

    func notice(_ text: String) {
        notices.insert(Notice(date: Date(), text: text), at: 0)
    }

    private static func describeCancelReason(_ reason: Int) -> String {
        switch reason {
        case NSURLErrorCancelledReasonUserForceQuitApplication:
            return "the app was closed from the app switcher."
        case NSURLErrorCancelledReasonBackgroundUpdatesDisabled:
            return "Background App Refresh is off for Prisma (Settings > General > Background App Refresh)."
        case NSURLErrorCancelledReasonInsufficientSystemResources:
            return "iOS was short of resources."
        default:
            return "reason code \(reason)."
        }
    }
}
