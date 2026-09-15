import Foundation
import Observation
import SwiftData

/// Deletes tracks from the server, then syncs so they leave this iPhone.
///
/// Nothing is deleted locally here. The delta sync that follows receives the ids in
/// `deleted_track_ids`, and `LibrarySync` removes each track the way it removes any
/// track the server dropped: its audio file and transfer (`DownloadManager.
/// discardLocalData`), its row, and with the row its favourite flag and every
/// playlist entry pointing at it (a cascade relationship).
@Observable
final class TrackDeletion {
    /// Tracks whose DELETE or follow-up sync is still running, by track id.
    private(set) var inProgress: Set<String> = []
    /// The last failed deletion, by the key it was started under: the track id for a
    /// row, the album or playlist key for a header. Shown until dismissed.
    private(set) var problems: [String: APIError] = [:]

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let sync: LibrarySync

    private struct Target {
        let id: String
        let title: String
    }

    init(context: ModelContext, settings: AppSettings, sync: LibrarySync) {
        self.context = context
        self.settings = settings
        self.sync = sync
    }

    /// Deletes `tracks` from the server one at a time, then syncs once. Tracks
    /// already being deleted are skipped.
    func delete(_ tracks: [StoredTrack], reportingUnder key: String) {
        var seen = Set<String>()
        let targets = tracks
            .filter { !$0.isDeleted && !inProgress.contains($0.serverID) && seen.insert($0.serverID).inserted }
            .map { Target(id: $0.serverID, title: $0.title ?? "Senza titolo") }
        problems[key] = nil
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        inProgress.formUnion(ids)
        Task {
            problems[key] = await run(targets)
            inProgress.subtract(ids)
        }
    }

    func clearProblem(_ key: String) {
        problems[key] = nil
    }

    // MARK: - Work

    private func run(_ targets: [Target]) async -> APIError? {
        let client: APIClient
        do {
            client = try settings.makeClient()
        } catch {
            return Self.failure(.from(error), title: targets[0].title, failed: targets.count, of: targets.count)
        }

        var deleted: [String] = []
        var firstFailure: (title: String, error: APIError)?
        var failed = 0
        for target in targets {
            do {
                _ = try await client.deleteTrack(trackID: target.id)
                deleted.append(target.id)
            } catch {
                failed += 1
                if firstFailure == nil {
                    firstFailure = (title: target.title, error: APIError.from(error))
                }
            }
        }

        var syncProblem: APIError?
        if !deleted.isEmpty {
            syncProblem = await syncAway(deleted)
        }
        if let firstFailure {
            return Self.failure(firstFailure.error, title: firstFailure.title, failed: failed, of: targets.count)
        }
        return syncProblem
    }

    /// Syncs until the deleted tracks are gone from this iPhone, or says why not.
    private func syncAway(_ ids: [String]) async -> APIError? {
        await sync.refresh()
        if stillInLibrary(ids) {
            // A sync already running when the deletion finished may have read the
            // catalogue before it: one more picks the deletion up.
            await sync.refresh()
        }
        guard stillInLibrary(ids) else { return nil }

        let lead = ids.count == 1
            ? "Il brano è stato eliminato dal server, ma la libreria sul telefono non si è ancora aggiornata: "
            : "I brani sono stati eliminati dal server, ma la libreria sul telefono non si è ancora aggiornata: "
        if case .failed(let error) = sync.status {
            var problem = error
            problem.message = lead + PlainLanguage.message(for: error).lowercasedFirst
            return problem
        }
        return .invalidInput(
            lead.trimmingCharacters(in: CharacterSet(charactersIn: ": ")),
            detail: "Trascina verso il basso in Libreria per sincronizzare di nuovo."
        )
    }

    private func stillInLibrary(_ ids: [String]) -> Bool {
        let wanted = Set(ids)
        do {
            return try context.fetch(FetchDescriptor<StoredTrack>()).contains { wanted.contains($0.serverID) }
        } catch {
            // Unreadable store: nothing more a sync could fix, and the library
            // screen reports storage problems itself.
            return false
        }
    }

    // MARK: - Messages

    /// What failed, for one track or a whole album or playlist, and what to do.
    private static func failure(_ error: APIError, title: String, failed: Int, of total: Int) -> APIError {
        let lead: String
        if total == 1 {
            lead = "“\(title)” non è stato eliminato dal server: "
        } else if failed == 1 {
            lead = "1 brano su \(total) non è stato eliminato dal server, “\(title)”: "
        } else {
            lead = "\(failed) brani su \(total) non sono stati eliminati dal server, tra cui “\(title)”: "
        }
        var problem = error
        problem.message = lead + reason(for: error)
        return problem
    }

    private static func reason(for error: APIError) -> String {
        if error.kind == .http {
            switch error.httpStatus {
            case 409?:
                return "il server lo sta scaricando o sta scrivendo nella libreria. Riprova tra poco."
            case 404?:
                return "il server non ha questo brano. Tocca Risincronizza tutto in Libreria per toglierlo anche dal telefono."
            case 405?:
                return "il backend non permette ancora di eliminare brani. Aggiorna il backend, poi riprova."
            case 500?:
                return "il server lo ha segnato come eliminato ma non è riuscito a rimuovere un file. Riprova."
            default:
                break
            }
        }
        return PlainLanguage.message(for: error).lowercasedFirst
    }
}
