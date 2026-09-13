import Foundation

/// A validated backend base URL, e.g. `http://hostname:8000`.
///
/// Parsing is strict and explains itself: a wrong address should produce a
/// readable message on the Settings screen, not a confusing network error later.
/// The normalised form has a lowercase scheme and no trailing slash.
nonisolated struct ServerAddress: Sendable, Equatable {
    let url: URL

    static func parse(_ raw: String) throws -> ServerAddress {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw APIError.notConfigured }

        let lowercased = text.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else {
            throw APIError.invalidAddress(text, reason: "It must start with http:// (the backend serves plain HTTP), for example http://hostname:8000.")
        }
        guard var components = URLComponents(string: text) else {
            throw APIError.invalidAddress(text, reason: "It is not a valid URL. Check for spaces or stray characters.")
        }
        guard let host = components.host, !host.isEmpty else {
            throw APIError.invalidAddress(text, reason: "It has no host name after http://.")
        }
        if components.user != nil || components.password != nil {
            throw APIError.invalidAddress(text, reason: "Remove the user name or password; the backend has no login.")
        }
        if components.query != nil || components.fragment != nil {
            throw APIError.invalidAddress(text, reason: "Remove everything from ? or # onwards.")
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw APIError.invalidAddress(text, reason: "Port \(port) is out of range (1 to 65535).")
        }

        components.scheme = components.scheme?.lowercased()
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path

        guard let url = components.url else {
            throw APIError.invalidAddress(text, reason: "iOS could not build a URL from it.")
        }
        return ServerAddress(url: url)
    }

    /// `path` must start with "/" and is appended to any path in the base URL, so
    /// a backend behind a path prefix still works.
    func endpoint(_ path: String, query: [(name: String, value: String)] = []) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidAddress(url.absoluteString, reason: "The saved address could not be split into URL parts.")
        }
        components.percentEncodedPath += path
        if !query.isEmpty {
            var pairs: [String] = []
            for item in query {
                let name = try Self.encode(item.name)
                let value = try Self.encode(item.value)
                pairs.append(name + "=" + value)
            }
            components.percentEncodedQuery = pairs.joined(separator: "&")
        }
        guard let result = components.url else {
            throw APIError.invalidInput("Could not build the request URL", detail: "Base \(url.absoluteString), path \(path).")
        }
        return result
    }

    /// Resolves a URL the server sent: absolute URLs (search artwork) are used as
    /// they are, relative ones (album covers) are resolved against this address.
    func resolve(_ reference: String) throws -> URL {
        if let absolute = URL(string: reference), let scheme = absolute.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return absolute
        }
        guard reference.hasPrefix("/"), let relative = URLComponents(string: reference) else {
            throw APIError.invalidInput("Unusable URL from the server", detail: "Expected an absolute URL or a path starting with /, got \"\(reference)\".")
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidAddress(url.absoluteString, reason: "The saved address could not be split into URL parts.")
        }
        components.percentEncodedPath += relative.percentEncodedPath
        components.percentEncodedQuery = relative.percentEncodedQuery
        guard let result = components.url else {
            throw APIError.invalidInput("Could not resolve a URL from the server", detail: "Base \(url.absoluteString), reference \(reference).")
        }
        return result
    }

    /// Percent-encodes one path segment, e.g. a track id, so it cannot add path levels.
    static func pathSegment(_ value: String) throws -> String {
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else {
            throw APIError.invalidInput("Could not encode a path segment", detail: "The text \"\(value)\" could not be percent-encoded.")
        }
        return encoded
    }

    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;")
        return allowed
    }()

    /// Query values are encoded strictly: "+" in particular, which the backend
    /// would otherwise read as a space.
    private static let queryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        return allowed
    }()

    private static func encode(_ value: String) throws -> String {
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) else {
            throw APIError.invalidInput("Could not encode the query", detail: "The text \"\(value)\" could not be percent-encoded.")
        }
        return encoded
    }
}
