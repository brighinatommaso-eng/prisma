import Foundation

/// What a background download task needs to know about its track, stored as JSON
/// in `URLSessionTask.taskDescription`.
///
/// The description survives app termination together with the task, so when iOS
/// relaunches the app to deliver a finished download, the delegate can verify and
/// file it without reading the database first. That matters because the
/// downloaded file only exists while `didFinishDownloadingTo` is running.
nonisolated struct DownloadTaskDescriptor: Codable, Sendable {
    let version: Int
    let trackID: String
    /// Matches `StoredTrack.downloadToken` for the current attempt.
    let token: String
    /// Lowercase hex, from /library.
    let sha256: String
    let fileBytes: Int

    nonisolated enum CodingKeys: String, CodingKey {
        case version
        case trackID
        case token
        case sha256
        case fileBytes
    }

    func encoded() throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(self)
        } catch {
            throw APIError.storage("Could not encode the download task description", location: nil, error: error)
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String?) -> Result<DownloadTaskDescriptor, APIError> {
        guard let text, !text.isEmpty else {
            return .failure(.invalidInput(
                "Transfer has no description",
                detail: "A background transfer carried no track information, so it could not be matched to a track."
            ))
        }
        do {
            return .success(try JSONDecoder().decode(DownloadTaskDescriptor.self, from: Data(text.utf8)))
        } catch {
            return .failure(.invalidInput(
                "Transfer description unreadable",
                detail: "Could not decode \"\(text)\": \(error.localizedDescription)"
            ))
        }
    }
}
