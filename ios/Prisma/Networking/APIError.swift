import Foundation

/// Every failure the app can show, already turned into readable text.
///
/// There is no console on the device, so an error is only useful if all of it
/// reaches the screen: what was attempted, what came back, and a hint. Each case
/// is built here once; views display `title` and `detailText` and never format
/// errors themselves.
nonisolated struct APIError: Error, LocalizedError, Sendable {
    nonisolated enum Kind: Sendable, Equatable {
        case notConfigured
        case invalidAddress
        case invalidInput
        case cancelled
        case transport
        case http
        case invalidResponse
        case decoding
        case notAnImage
        case storage
        case verification
        case unexpected
    }

    let kind: Kind
    let title: String
    /// The URL that was attempted, when there was one.
    let url: String?
    let details: [String]

    var errorDescription: String? { title }

    var isCancellation: Bool { kind == .cancelled }

    var detailText: String {
        ((url.map { ["URL: \($0)"] } ?? []) + details).joined(separator: "\n")
    }

    /// Everything, for the clipboard.
    var fullText: String { title + "\n" + detailText }

    /// Short form for a list row, where the full report would not fit.
    var oneLine: String {
        ([title] + Array(details.prefix(1)) + (url.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// Wraps anything thrown into an APIError, so a caller never has to drop an
    /// error it does not recognise.
    static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError { return apiError }
        if error is CancellationError { return cancelled(url: nil) }
        if let urlError = error as? URLError {
            return transport(urlError, url: urlError.failingURL)
        }
        return unexpected(error, url: nil)
    }

    // MARK: - Configuration and input

    static let notConfigured = APIError(
        kind: .notConfigured,
        title: "No server address set",
        url: nil,
        details: ["Enter the backend address in the Settings tab, for example http://hostname:8000, and tap Save."]
    )

    static func invalidAddress(_ text: String, reason: String) -> APIError {
        APIError(
            kind: .invalidAddress,
            title: "Invalid server address",
            url: nil,
            details: ["You entered: \"\(text)\"", reason]
        )
    }

    static func invalidInput(_ title: String, detail: String) -> APIError {
        APIError(kind: .invalidInput, title: title, url: nil, details: [detail])
    }

    static func cancelled(url: URL?) -> APIError {
        APIError(
            kind: .cancelled,
            title: "Request cancelled",
            url: url?.absoluteString,
            details: ["The request was cancelled before it finished. Try again."]
        )
    }

    // MARK: - Network

    static func transport(_ error: Error, url: URL?) -> APIError {
        if error is CancellationError { return cancelled(url: url) }
        guard let urlError = error as? URLError else { return unexpected(error, url: url) }
        if urlError.code == .cancelled { return cancelled(url: url) }

        let nsError = urlError as NSError
        var lines = [
            "URLError code: \(urlError.code.rawValue) (\(name(of: urlError.code)))",
            "Description: \(urlError.localizedDescription)",
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("Underlying: \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
        }
        // Names the reason iOS considers the path unusable, e.g.
        // "unsatisfied (Local network prohibited)".
        if let path = nsError.userInfo["_NSURLErrorNWPathKey"] {
            lines.append("Network path: \(String(describing: path))")
        }
        if let hint = hint(for: urlError.code) {
            lines.append("Hint: \(hint)")
        }
        return APIError(
            kind: .transport,
            title: "Could not reach the server",
            url: (url ?? urlError.failingURL)?.absoluteString,
            details: lines
        )
    }

    static func http(status: Int, url: URL, contentType: String?, body: Data) -> APIError {
        var lines = [
            "HTTP status: \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))",
            "Content-Type: \(contentType ?? "(none)")",
        ]
        if let detail = fastAPIDetail(in: body) {
            lines.append("Server says: \(detail)")
        }
        lines.append("Body (\(body.count) bytes): \(preview(body, contentType: contentType))")
        if status == 404 {
            lines.append("Hint: this path does not exist on the server. Check the address points at the Prisma backend, and that the deployed backend has this endpoint.")
        }
        return APIError(kind: .http, title: "Server returned HTTP \(status)", url: url.absoluteString, details: lines)
    }

    static func invalidResponse(url: URL, response: URLResponse) -> APIError {
        APIError(
            kind: .invalidResponse,
            title: "Response was not HTTP",
            url: url.absoluteString,
            details: ["Got \(String(describing: type(of: response))) instead of an HTTP response."]
        )
    }

    // MARK: - Content

    static func decoding(_ error: Error, url: URL, body: Data) -> APIError {
        var lines: [String]
        if let decodingError = error as? DecodingError {
            lines = describe(decodingError)
        } else {
            lines = ["\(String(describing: type(of: error))): \(error.localizedDescription)"]
        }
        lines.append("Body (\(body.count) bytes): \(preview(body, contentType: "application/json"))")
        lines.append("Hint: the backend's JSON does not match what this app build expects. The app and backend may be out of step.")
        return APIError(
            kind: .decoding,
            title: "The server's response could not be read",
            url: url.absoluteString,
            details: lines
        )
    }

    static func notAnImage(url: URL, contentType: String?, byteCount: Int) -> APIError {
        APIError(
            kind: .notAnImage,
            title: "Not an image",
            url: url.absoluteString,
            details: ["Received \(byteCount) bytes with Content-Type \(contentType ?? "(none)"), not an image type."]
        )
    }

    static func undecodableImage(url: URL, byteCount: Int) -> APIError {
        APIError(
            kind: .notAnImage,
            title: "Image could not be decoded",
            url: url.absoluteString,
            details: ["The server declared \(byteCount) bytes of image data, but iOS could not decode them."]
        )
    }

    /// A file or database operation failed. `location` is a file path or URL.
    static func storage(_ title: String, location: URL?, error: Error) -> APIError {
        if let apiError = error as? APIError {
            return APIError(kind: .storage, title: title, url: location?.path(percentEncoded: false),
                            details: [apiError.title] + apiError.details)
        }
        let nsError = error as NSError
        return APIError(
            kind: .storage,
            title: title,
            url: location?.path(percentEncoded: false),
            details: [
                "\(nsError.domain) \(nsError.code): \(error.localizedDescription)",
                "Debug: \(String(describing: error))",
            ]
        )
    }

    static func unexpected(_ error: Error, url: URL?) -> APIError {
        let nsError = error as NSError
        return APIError(
            kind: .unexpected,
            title: "Unexpected error",
            url: url?.absoluteString,
            details: [
                "Type: \(String(describing: type(of: error)))",
                "Domain/code: \(nsError.domain) \(nsError.code)",
                "Description: \(error.localizedDescription)",
                "Debug: \(String(describing: error))",
            ]
        )
    }

    // MARK: - Helpers

    private static func describe(_ error: DecodingError) -> [String] {
        func path(_ keys: [any CodingKey]) -> String {
            let text = keys.map { key in
                key.intValue.map { "[\($0)]" } ?? ".\(key.stringValue)"
            }.joined()
            if text.isEmpty { return "(top level)" }
            return text.hasPrefix(".") ? String(text.dropFirst()) : text
        }
        func underlying(_ context: DecodingError.Context) -> [String] {
            guard let error = context.underlyingError else { return [] }
            return ["Underlying: \(error.localizedDescription)"]
        }

        switch error {
        case .typeMismatch(let expected, let context):
            return ["Wrong type at \(path(context.codingPath)): expected \(expected)", context.debugDescription]
                + underlying(context)
        case .valueNotFound(let expected, let context):
            return ["Missing value at \(path(context.codingPath)): expected \(expected), got null", context.debugDescription]
                + underlying(context)
        case .keyNotFound(let key, let context):
            let parent = context.codingPath.isEmpty ? "the top level" : path(context.codingPath)
            return ["Missing key \"\(key.stringValue)\" in \(parent)", context.debugDescription]
                + underlying(context)
        case .dataCorrupted(let context):
            return ["Invalid data at \(path(context.codingPath))", context.debugDescription]
                + underlying(context)
        @unknown default:
            return [String(describing: error)]
        }
    }

    /// FastAPI puts its error message in {"detail": "..."}.
    private static func fastAPIDetail(in body: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            let dictionary = object as? [String: Any],
            let detail = dictionary["detail"]
        else { return nil }
        return String(describing: detail)
    }

    private static func preview(_ body: Data, contentType: String?) -> String {
        if body.isEmpty { return "(empty)" }
        if let contentType, contentType.lowercased().hasPrefix("image/") { return "(image data)" }
        let limit = 1500
        let text = String(decoding: body.prefix(limit), as: UTF8.self)
        return body.count > limit ? text + " …(truncated)" : text
    }

    private static func name(of code: URLError.Code) -> String {
        switch code.rawValue {
        case -999: return "cancelled"
        case -1000: return "badURL"
        case -1001: return "timedOut"
        case -1002: return "unsupportedURL"
        case -1003: return "cannotFindHost"
        case -1004: return "cannotConnectToHost"
        case -1005: return "networkConnectionLost"
        case -1006: return "dnsLookupFailed"
        case -1009: return "notConnectedToInternet"
        case -1011: return "badServerResponse"
        case -1017: return "cannotParseResponse"
        case -1018: return "internationalRoamingOff"
        case -1020: return "dataNotAllowed"
        case -1022: return "appTransportSecurityRequiresSecureConnection"
        case -1200: return "secureConnectionFailed"
        case -1202: return "serverCertificateUntrusted"
        default: return "see Apple's URLError.Code list"
        }
    }

    private static func hint(for code: URLError.Code) -> String? {
        switch code.rawValue {
        case -1009:
            return "iOS reports no usable network: airplane mode, or Wi-Fi and mobile data both off. For a LAN address it also means Local Network access is denied: Settings > Privacy & Security > Local Network > Prisma."
        case -1003, -1006:
            return "The host name did not resolve. Check the spelling. For a Tailscale name, check the Tailscale app is connected on this iPhone."
        case -1004:
            return "The host answered but nothing accepted the connection on that port. Check the port number and that the backend container is running."
        case -1001:
            return "No response in time. Usually the host is unreachable: Tailscale disconnected, wrong IP address, or the server is off."
        case -1005:
            return "The connection dropped mid-request. Try again; if it repeats, the server may be restarting."
        case -1020:
            return "Mobile data is turned off for Prisma: Settings > Prisma > Mobile Data."
        case -1022:
            return "iOS blocked plain HTTP. This build is missing its App Transport Security exception in Info.plist."
        case -1200, -1202:
            return "The TLS handshake failed. The backend serves plain HTTP: use http://, not https://."
        case -1011, -1017:
            return "Something answered, but not with a valid HTTP response. Check the address points at the Prisma backend."
        default:
            return nil
        }
    }
}
