import Foundation
import SwiftData

/// Everything that must exist exactly once per process, created at launch.
///
/// Both the SwiftUI app and the app delegate reach it through `shared`, so the
/// background download session exists before iOS delivers any of its events,
/// including when iOS launches the app in the background without showing a view.
final class AppModel {
    static let shared = AppModel()

    struct Services {
        let container: ModelContainer
        let downloads: DownloadManager
        let sync: LibrarySync
    }

    let settings: AppSettings
    /// nil only when the database could not be opened; `launchError` says why.
    let services: Services?
    let launchError: APIError?

    private init() {
        let settings = AppSettings()
        self.settings = settings
        do {
            let container = try ModelContainer(for: StoredAlbum.self, StoredTrack.self, SyncRecord.self)
            let downloads = DownloadManager(context: container.mainContext, settings: settings)
            let sync = LibrarySync(context: container.mainContext, settings: settings, downloads: downloads)
            services = Services(container: container, downloads: downloads, sync: sync)
            launchError = nil
            downloads.checkTransfers(reason: "app launch")
        } catch {
            services = nil
            launchError = .storage("The local library database could not be opened", location: nil, error: error)
        }
    }
}
