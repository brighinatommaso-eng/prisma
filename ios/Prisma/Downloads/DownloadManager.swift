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

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?
    @ObservationIgnored private var eventsDeliveredBeforeHandler = false

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
        switch track.downloadState {
        case .notDownloaded, .failed, .cancelled:
            do {
                try start(track, note: nil)
            } catch {
                refusals[track.serverID] = .from(error)
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
            runCheck(tasks: tasks, reason: reason)
            isChecking = false
        }
    }

    private func runCheck(tasks: [URLSessionTask], reason: String) {
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
            return
        }

        let recovered = recoverAndCleanMusicFiles(tracks: tracks)

        var restarted = 0
        for track in tracks where track.downloadState == .queued || track.downloadState == .downloading {
            if let token = track.downloadToken, liveTokens.contains(token) { continue }
            // Changed in the last few seconds: its completion event may still be on the way.
            if let changed = track.stateChangedAt, Date().timeIntervalSince(changed) < 5 { continue }
            track.downloadToken = nil
            track.taskIdentifier = nil
            let resuming = track.resumeData != nil
            do {
                try start(track, note: "Restarted automatically (\(reason)): iOS no longer had a transfer for it"
                    + (resuming ? ", resuming from where it stopped." : ", starting from the beginning."))
                restarted += 1
            } catch {
                track.errorText = "Its transfer was lost (\(reason)) and could not be restarted.\n" + APIError.from(error).fullText
                track.downloadState = .failed
            }
        }

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
        if restarted > 0 { summary.append("restarted \(restarted) lost transfer(s)") }
        if recovered.adopted > 0 { summary.append("recovered \(recovered.adopted) verified file(s) from interrupted transfers") }
        if recovered.removed > 0 { summary.append("deleted \(recovered.removed) stray file(s)") }
        if missing > 0 { summary.append("\(missing) downloaded track(s) had lost their file and were marked failed") }
        if !summary.isEmpty {
            notice("Transfer check (\(reason)): " + summary.joined(separator: "; ") + ".")
        }
        save("recording the transfer check")
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

    private func start(_ track: StoredTrack, note: String?) throws {
        guard let session else {
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
        let url = try settings.makeClient().trackFileURL(trackID: track.serverID)
        try checkFreeSpace(for: track, bytes: bytes)

        let token = UUID().uuidString
        let description = try DownloadTaskDescriptor(
            version: 1, trackID: track.serverID, token: token, sha256: sha, fileBytes: bytes
        ).encoded()

        let task: URLSessionDownloadTask
        if let resumeData = track.resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url)
            request.setValue("audio/*", forHTTPHeaderField: "Accept")
            task = session.downloadTask(with: request)
        }
        task.taskDescription = description

        // Consumed: if this attempt fails, its own resume data replaces it.
        track.resumeData = nil
        track.downloadToken = token
        track.taskIdentifier = task.taskIdentifier
        track.queuedAt = Date()
        track.errorText = nil
        track.note = note
        track.downloadState = .queued
        save("queueing a download")
        task.resume()
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
                // not the user asking to stop this download, so start it again.
                track.downloadState = .notDownloaded
                do {
                    try start(track, note: "Restarted automatically: closing the app from the app switcher stopped the transfer"
                        + (resumeData != nil ? ". Resuming from where it stopped." : ". Starting from the beginning."))
                    return
                } catch {
                    track.errorText = "The app was closed from the app switcher, which stopped the transfer, and it could not be restarted.\n"
                        + APIError.from(error).fullText
                    track.downloadState = .failed
                }
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
