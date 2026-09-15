import Foundation
import Observation

@Observable
final class SearchModel {
    nonisolated struct Results: Sendable {
        let query: String
        let response: APIResponse<[SongResult]>
        /// The client that produced the results, so artwork resolves against the
        /// same address even if Settings changes meanwhile.
        let client: APIClient
    }

    var query = ""
    private(set) var state: LoadState<Results> = .idle

    /// Incremented per search. A response only updates `state` if no newer
    /// search has started, so a slow old response cannot replace newer results.
    private var generation = 0

    func search(settings: AppSettings) {
        generation += 1
        let current = generation

        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            state = .failed(.invalidInput("Non c'è niente da cercare", detail: "Scrivi prima un brano, un artista o un album."))
            return
        }
        let client: APIClient
        do {
            client = try settings.makeClient()
        } catch {
            state = .failed(.from(error))
            return
        }

        state = .loading(since: Date())
        // Unstructured on purpose: leaving the tab must not cancel the request and
        // strand the screen in `loading`.
        Task {
            let outcome: LoadState<Results>
            do {
                let response = try await client.search(query: text)
                outcome = .loaded(Results(query: text, response: response, client: client))
            } catch {
                outcome = .failed(.from(error))
            }
            guard current == generation else { return }
            state = outcome
        }
    }
}
