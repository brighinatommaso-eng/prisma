import Foundation

/// The result of handling a finished transfer's file.
nonisolated enum DownloadOutcome: Sendable {
    /// Verified and stored as Application Support/Music/`fileName`.
    case verified(fileName: String, bytes: Int)
    /// Nothing stored; the error says why and whether a file was left behind.
    case failed(APIError)
}

/// Checks a downloaded file and moves it into the library.
///
/// Runs synchronously inside `urlSession(_:downloadTask:didFinishDownloadingTo:)`
/// on the delegate queue, because iOS deletes the temporary file as soon as that
/// method returns. Nothing here may hop to another thread before the file has
/// been moved.
nonisolated enum DownloadFinalizer {
    static func finalize(
        location: URL,
        response: URLResponse?,
        requestURL: URL?,
        descriptor: DownloadTaskDescriptor
    ) -> DownloadOutcome {
        let requestText = requestURL?.absoluteString

        guard let http = response as? HTTPURLResponse else {
            return .failed(APIError(
                kind: .invalidResponse,
                title: "Download did not return an HTTP response",
                url: requestText,
                details: ["Response: \(String(describing: response))"]
            ))
        }

        // A download task saves the body whatever the status, so an error page
        // arrives here as a "file". Report it and store nothing.
        guard (200...299).contains(http.statusCode) else {
            let body: Data
            var readProblem: String?
            do {
                body = try Data(contentsOf: location, options: .mappedIfSafe).prefix(4096)
            } catch {
                body = Data()
                readProblem = "The error body could not be read: \(error.localizedDescription)"
            }
            let error = APIError.http(
                status: http.statusCode,
                url: requestURL ?? location,
                contentType: http.value(forHTTPHeaderField: "Content-Type"),
                body: body
            )
            guard let readProblem else { return .failed(error) }
            return .failed(APIError(kind: error.kind, title: error.title, url: error.url, details: error.details + [readProblem]))
        }

        let partial: URL
        let final: URL
        do {
            partial = try LocalFiles.url(.music, LocalFiles.partialFileName(trackID: descriptor.trackID, token: descriptor.token))
            final = try LocalFiles.url(.music, LocalFiles.musicFileName(trackID: descriptor.trackID))
        } catch {
            return .failed(.storage("Could not create the Music folder in Application Support", location: nil, error: error))
        }

        do {
            try LocalFiles.removeIfPresent(partial)
            try FileManager.default.moveItem(at: location, to: partial)
        } catch {
            return .failed(.storage("Could not move the downloaded file into Application Support", location: partial, error: error))
        }

        let size: Int
        let actual: String
        do {
            size = try LocalFiles.fileSize(partial)
            actual = try LocalFiles.sha256Hex(of: partial)
        } catch {
            return .failed(withCleanup(
                .storage("Could not read the downloaded file to verify it", location: partial, error: error),
                partial: partial
            ))
        }

        let expected = descriptor.sha256.lowercased()
        guard actual == expected else {
            let error = APIError(
                kind: .verification,
                title: "Downloaded file failed SHA-256 verification",
                url: requestText,
                details: [
                    "Expected (from /library): \(expected)",
                    "Actual (received file):   \(actual)",
                    "X-Prisma-SHA256 header:   \(http.value(forHTTPHeaderField: "X-Prisma-SHA256") ?? "(absent)")",
                    "Bytes received: \(size), expected: \(descriptor.fileBytes)",
                    "Hint: the transfer was damaged, or the server's file changed after the last sync. Sync the library, then retry.",
                ]
            )
            return .failed(withCleanup(error, partial: partial))
        }

        do {
            if LocalFiles.exists(final) {
                _ = try FileManager.default.replaceItemAt(final, withItemAt: partial)
            } else {
                try FileManager.default.moveItem(at: partial, to: final)
            }
            try LocalFiles.excludeFromBackup(final)
        } catch {
            return .failed(withCleanup(
                .storage("Could not store the verified file", location: final, error: error),
                partial: partial
            ))
        }
        return .verified(fileName: final.lastPathComponent, bytes: size)
    }

    /// Deletes the partial file and says in the error whether that worked.
    private static func withCleanup(_ error: APIError, partial: URL) -> APIError {
        let line: String
        do {
            try LocalFiles.removeIfPresent(partial)
            line = "The received file was deleted."
        } catch let removal {
            line = "The received file could NOT be deleted (\(removal.localizedDescription)). It will be removed at the next launch."
        }
        return APIError(kind: error.kind, title: error.title, url: error.url, details: error.details + [line])
    }
}
