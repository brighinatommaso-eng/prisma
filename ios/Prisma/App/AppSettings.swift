import Foundation
import Observation

/// The server address, stored in UserDefaults on this iPhone. It is the only
/// thing the app persists, and it never appears in source: the repo is public.
@Observable
final class AppSettings {
    private static let serverAddressKey = "serverAddress"

    @ObservationIgnored private let defaults: UserDefaults

    /// The normalised address as saved, or "" when none has been saved.
    private(set) var savedAddress: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        savedAddress = defaults.string(forKey: Self.serverAddressKey) ?? ""
    }

    /// Validates and stores an address. Throws an APIError describing what is
    /// wrong with it, and stores nothing in that case.
    @discardableResult
    func save(_ text: String) throws -> ServerAddress {
        let address = try ServerAddress.parse(text)
        let value = address.url.absoluteString
        defaults.set(value, forKey: Self.serverAddressKey)
        savedAddress = value
        return address
    }

    /// A client for the saved address. Throws `APIError.notConfigured` when no
    /// address has been saved.
    func makeClient() throws -> APIClient {
        APIClient(address: try ServerAddress.parse(savedAddress))
    }
}
