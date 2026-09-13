import Foundation

/// A decoded response plus what is needed to show where it came from.
nonisolated struct APIResponse<Value: Sendable>: Sendable {
    let value: Value
    let url: URL
    let status: Int
    let milliseconds: Int
    let receivedAt: Date
    let body: Data

    var bodyText: String { String(decoding: body, as: UTF8.self) }
}

/// Result of a conditional cover request.
nonisolated enum CoverFetch: Sendable {
    /// 304: the file already on disk is current.
    case notModified
    case downloaded(Data, etag: String?)
}

/// The only code that talks to the Prisma backend in the foreground.
///
/// Views never build URLs: they call a method here and get a decoded value, or an
/// `APIError` that already holds the full on-screen text. Audio downloads go
/// through `DownloadManager`'s background session, but take their URL from here.
nonisolated struct APIClient: Sendable {
    /// Idle timeouts in seconds: how long a request may go without receiving data
    /// before failing with URLError.timedOut. Each is longer than the backend's own
    /// upstream timeout, so a slow YouTube shows the server's message rather than
    /// a client timeout.
    nonisolated enum Timeout {
        /// The backend probes YouTube Music for up to 8 s.
        static let health: TimeInterval = 20
        /// The backend allows YouTube Music 20 s, then HEAD-checks each artwork URL.
        static let search: TimeInterval = 45
        static let library: TimeInterval = 20
        static let image: TimeInterval = 20
    }

    let address: ServerAddress

    init(address: ServerAddress) {
        self.address = address
    }

    private static let session: URLSession = {
        // Ephemeral: nothing is written to disk by URLSession. Covers the app keeps
        // are written explicitly by LibrarySync.
        let configuration = URLSessionConfiguration.ephemeral
        // Fail immediately with no network (airplane mode) rather than waiting for
        // a connection to appear.
        configuration.waitsForConnectivity = false
        // Upper bound on a whole request, even one that keeps trickling data, so no
        // screen can stay in a loading state indefinitely.
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    func health() async throws -> APIResponse<Health> {
        try await getJSON("/health", timeout: Timeout.health)
    }

    func search(query: String, limit: Int = 20) async throws -> APIResponse<[SongResult]> {
        try await getJSON(
            "/search",
            query: [(name: "q", value: query), (name: "limit", value: String(limit))],
            timeout: Timeout.search
        )
    }

    /// The full catalogue when `since` is nil, otherwise only what changed after it.
    func library(since: Int?) async throws -> APIResponse<Library> {
        var query: [(name: String, value: String)] = []
        if let since {
            query.append((name: "since", value: String(since)))
        }
        return try await getJSON("/library", query: query, timeout: Timeout.library)
    }

    /// Turns an artwork or cover URL from a response into a request URL.
    func resolve(_ reference: String) throws -> URL {
        try address.resolve(reference)
    }

    /// GET /tracks/{id}/file, for the background download session.
    func trackFileURL(trackID: String) throws -> URL {
        let segment = try ServerAddress.pathSegment(trackID)
        return try address.endpoint("/tracks/" + segment + "/file")
    }

    /// Image bytes, checked to be declared as an image. The caller still has to
    /// decode them, and must report a failure to decode.
    func imageData(at url: URL) async throws -> Data {
        let fetched = try await fetch(url, accept: "image/*", timeout: Timeout.image)
        guard let contentType = fetched.contentType, contentType.lowercased().hasPrefix("image/") else {
            throw APIError.notAnImage(url: url, contentType: fetched.contentType, byteCount: fetched.data.count)
        }
        return fetched.data
    }

    /// A cover, skipped with 304 when `etag` still matches the server's file.
    func cover(at url: URL, etag: String?) async throws -> CoverFetch {
        var headers: [String: String] = [:]
        if let etag {
            headers["If-None-Match"] = etag
        }
        let fetched = try await fetch(url, accept: "image/*", timeout: Timeout.image, headers: headers)
        if fetched.status == 304 {
            return .notModified
        }
        guard let contentType = fetched.contentType, contentType.lowercased().hasPrefix("image/") else {
            throw APIError.notAnImage(url: url, contentType: fetched.contentType, byteCount: fetched.data.count)
        }
        return .downloaded(fetched.data, etag: fetched.etag)
    }

    // MARK: - Transport

    private nonisolated struct Fetched: Sendable {
        let data: Data
        let status: Int
        let contentType: String?
        let etag: String?
        let milliseconds: Int
    }

    private func getJSON<Value: Decodable & Sendable>(
        _ path: String,
        query: [(name: String, value: String)] = [],
        timeout: TimeInterval
    ) async throws -> APIResponse<Value> {
        let url = try address.endpoint(path, query: query)
        let fetched = try await fetch(url, accept: "application/json", timeout: timeout)
        let value: Value
        do {
            value = try JSONDecoder().decode(Value.self, from: fetched.data)
        } catch {
            throw APIError.decoding(error, url: url, body: fetched.data)
        }
        return APIResponse(
            value: value,
            url: url,
            status: fetched.status,
            milliseconds: fetched.milliseconds,
            receivedAt: Date(),
            body: fetched.data
        )
    }

    private func fetch(
        _ url: URL,
        accept: String,
        timeout: TimeInterval,
        headers: [String: String] = [:]
    ) async throws -> Fetched {
        // A conditional request must reach the server, not be answered from the
        // in-memory cache, so its 304 comes back to the caller.
        let isConditional = headers["If-None-Match"] != nil
        var request = URLRequest(
            url: url,
            cachePolicy: isConditional ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
            timeoutInterval: timeout
        )
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let clock = ContinuousClock()
        let start = clock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw APIError.transport(error, url: url)
        }
        let elapsed = clock.now - start
        let milliseconds = Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse(url: url, response: response)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        let isNotModified = isConditional && http.statusCode == 304
        guard (200...299).contains(http.statusCode) || isNotModified else {
            throw APIError.http(status: http.statusCode, url: url, contentType: contentType, body: data)
        }
        return Fetched(
            data: data,
            status: http.statusCode,
            contentType: contentType,
            etag: http.value(forHTTPHeaderField: "ETag"),
            milliseconds: milliseconds
        )
    }
}
