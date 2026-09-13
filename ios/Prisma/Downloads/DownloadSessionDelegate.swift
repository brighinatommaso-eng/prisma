import Foundation

/// How a transfer ended, as seen by the session delegate.
nonisolated enum TaskResult: Sendable {
    /// The server answered and the file was handled (verified or rejected).
    case outcome(DownloadOutcome)
    /// No file: a network error, or a cancellation by the user or by iOS.
    /// `systemCancelReason` is `NSURLErrorBackgroundTaskCancelledReasonKey`.
    case transportError(APIError, resumeData: Data?, systemCancelReason: Int?)
}

nonisolated enum DownloadEvent: Sendable {
    case progress(trackID: String, token: String, received: Int64, expected: Int64)
    case finished(trackID: String, token: String, result: TaskResult)
    case unmatched(taskIdentifier: Int, error: APIError)
    /// iOS has delivered every event queued for the background session.
    case allEventsDelivered
}

/// The one delegate of the background download session.
///
/// It never touches SwiftData or the UI. It verifies and files downloads on the
/// session's serial queue and passes each event to `deliver`, which hands it to
/// `DownloadManager` on the main thread in the order the events happened.
nonisolated final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let deliver: @Sendable (DownloadEvent) -> Void

    private let lock = NSLock()
    /// Outcomes from didFinishDownloadingTo, reported at didCompleteWithError.
    private var staged: [Int: DownloadOutcome] = [:]
    private var lastProgress: [Int: Date] = [:]

    init(deliver: @escaping @Sendable (DownloadEvent) -> Void) {
        self.deliver = deliver
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        reportProgress(downloadTask, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        reportProgress(downloadTask, received: fileOffset, expected: expectedTotalBytes, force: true)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let outcome: DownloadOutcome
        switch DownloadTaskDescriptor.decode(downloadTask.taskDescription) {
        case .success(let descriptor):
            outcome = DownloadFinalizer.finalize(
                location: location,
                response: downloadTask.response,
                requestURL: downloadTask.originalRequest?.url,
                descriptor: descriptor
            )
        case .failure(let error):
            // Without a descriptor there is no track to file it under; the system
            // deletes the temporary file when this returns.
            outcome = .failed(error)
        }
        let identifier = downloadTask.taskIdentifier
        lock.withLock { staged[identifier] = outcome }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let identifier = task.taskIdentifier
        let outcome = lock.withLock { () -> DownloadOutcome? in
            lastProgress[identifier] = nil
            return staged.removeValue(forKey: identifier)
        }

        let descriptor: DownloadTaskDescriptor
        switch DownloadTaskDescriptor.decode(task.taskDescription) {
        case .success(let decoded):
            descriptor = decoded
        case .failure(let decodeError):
            deliver(.unmatched(taskIdentifier: identifier, error: decodeError))
            return
        }

        let result: TaskResult
        if let outcome {
            result = .outcome(outcome)
        } else if let error {
            let nsError = error as NSError
            result = .transportError(
                .transport(error, url: task.originalRequest?.url),
                resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                systemCancelReason: nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
            )
        } else {
            result = .outcome(.failed(APIError(
                kind: .unexpected,
                title: "Transfer ended without a file",
                url: task.originalRequest?.url?.absoluteString,
                details: ["iOS reported the transfer as complete but delivered no file and no error."]
            )))
        }
        deliver(.finished(trackID: descriptor.trackID, token: descriptor.token, result: result))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        deliver(.allEventsDelivered)
    }

    /// At most about three updates a second per task, plus the final one.
    private func reportProgress(_ task: URLSessionTask, received: Int64, expected: Int64, force: Bool = false) {
        let identifier = task.taskIdentifier
        let now = Date()
        let shouldReport = lock.withLock { () -> Bool in
            if !force, received != expected, let last = lastProgress[identifier], now.timeIntervalSince(last) < 0.3 {
                return false
            }
            lastProgress[identifier] = now
            return true
        }
        guard shouldReport else { return }
        // A task without a readable description is reported once, by
        // didCompleteWithError; repeating it per progress tick would only add noise.
        guard case .success(let descriptor) = DownloadTaskDescriptor.decode(task.taskDescription) else { return }
        deliver(.progress(trackID: descriptor.trackID, token: descriptor.token, received: received, expected: expected))
    }
}
