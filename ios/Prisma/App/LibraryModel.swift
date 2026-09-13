import Foundation
import Observation

/// The server's catalogue, held in memory only and refetched on demand.
@Observable
final class LibraryModel {
    nonisolated struct Loaded: Sendable {
        let response: APIResponse<Library>
        /// The client that produced the response, so covers resolve against the
        /// same address.
        let client: APIClient
    }

    private(set) var state: LoadState<Loaded> = .idle

    /// Incremented per load. Only the newest load writes `state`, and it always
    /// does, whether it succeeds, fails or is cancelled.
    private var generation = 0
    /// The saved address the current state belongs to.
    private var loadedAddress: String?

    /// Loads on first appearance, and again if the saved address has changed.
    func loadIfNeeded(settings: AppSettings) {
        if case .idle = state {
            load(settings: settings)
        } else if loadedAddress != settings.savedAddress {
            load(settings: settings)
        }
    }

    func load(settings: AppSettings) {
        _ = start(settings: settings)
    }

    /// For pull-to-refresh: returns when the load has finished.
    func refresh(settings: AppSettings) async {
        await start(settings: settings).value
    }

    private func start(settings: AppSettings) -> Task<Void, Never> {
        generation += 1
        let current = generation
        loadedAddress = settings.savedAddress

        let client: APIClient
        do {
            client = try settings.makeClient()
        } catch {
            state = .failed(.from(error))
            return Task {}
        }

        state = .loading(since: Date())
        // Unstructured, so SwiftUI cancelling the refresh gesture's own task
        // cannot abandon the request halfway.
        return Task {
            let outcome: LoadState<Loaded>
            do {
                outcome = .loaded(Loaded(response: try await client.library(), client: client))
            } catch {
                outcome = .failed(.from(error))
            }
            guard current == generation else { return }
            state = outcome
        }
    }
}
