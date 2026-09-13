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

/// The only code that talks to the Prisma backend.
///
/// Views never build URLs: they call a method here and get a decoded value, or an
/// `APIError` that already holds the full on-screen text. The client holds no
/// state besides the address, so it is cheap to create for each request.
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
        // Ephemeral: nothing is written to disk. Persistence arrives with downloads.
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

    /// The full catalogue: no `since`, so no delta logic yet.
    func library() async throws -> APIResponse<Library> {
        try await getJSON("/library", timeout: Timeout.library)
    }

    /// Turns an artwork or cover URL from a response into a request URL.
    func resolve(_ reference: String) throws -> URL {
        try address.resolve(reference)
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

    // MARK: - Transport

    private nonisolated struct Fetched: Sendable {
        let data: Data
        let status: Int
        let contentType: String?
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

    private func fetch(_ url: URL, accept: String, timeout: TimeInterval) async throws -> Fetched {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: timeout)
        request.setValue(accept, forHTTPHeaderField: "Accept")

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
        guard (200...299).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode, url: url, contentType: contentType, body: data)
        }
        return Fetched(data: data, status: http.statusCode, contentType: contentType, milliseconds: milliseconds)
    }
}
