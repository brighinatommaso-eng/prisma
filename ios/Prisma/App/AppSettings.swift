import Foundation
import Observation

/// The server address, stored in UserDefaults on this iPhone. It is the only
/// thing the app persists, and it never appears in source: the repo is public.
@Observable
final class AppSettings {
    private static let serverAddressKey = "serverAddress"

    @ObservationIgnored private let defaults: UserDefaults

    /// Called after a different address is saved, with the previous and new value.
    /// AppModel points this at DownloadManager, so queued work follows the address.
    @ObservationIgnored var onAddressChange: ((_ previous: String, _ new: String) -> Void)?

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
        let previous = savedAddress
        defaults.set(value, forKey: Self.serverAddressKey)
        savedAddress = value
        if previous != value {
            onAddressChange?(previous, value)
        }
        return address
    }

    /// A client for the saved address. Throws `APIError.notConfigured` when no
    /// address has been saved.
    func makeClient() throws -> APIClient {
        APIClient(address: try ServerAddress.parse(savedAddress))
    }
}
