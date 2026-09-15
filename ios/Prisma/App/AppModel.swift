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
        let playback: PlaybackEngine
        let theme: ThemeEngine
        let playlists: PlaylistStore
        let acquisitions: AcquisitionCoordinator
    }

    let settings: AppSettings
    /// nil only when the database could not be opened; `launchError` says why.
    let services: Services?
    let launchError: APIError?

    private init() {
        let settings = AppSettings()
        self.settings = settings
        do {
            let container = try ModelContainer(for: StoredAlbum.self, StoredTrack.self, SyncRecord.self, Playlist.self, PlaylistEntry.self, PendingAcquisition.self)
            let downloads = DownloadManager(context: container.mainContext, settings: settings)
            let sync = LibrarySync(context: container.mainContext, settings: settings, downloads: downloads)
            settings.onAddressChange = { [downloads] previous, new in
                downloads.serverAddressChanged(from: previous, to: new)
            }
            let playback = PlaybackEngine(context: container.mainContext, downloads: downloads)
            let theme = ThemeEngine(playback: playback)
            let playlists = PlaylistStore(context: container.mainContext, downloads: downloads, playback: playback)
            // Created here but idle: it only runs once RootView reports the app is
            // in the foreground, never during a background launch.
            let acquisitions = AcquisitionCoordinator(context: container.mainContext, settings: settings, sync: sync, downloads: downloads)
            services = Services(container: container, downloads: downloads, sync: sync, playback: playback, theme: theme, playlists: playlists, acquisitions: acquisitions)
            playlists.removeOrphanedEntries()
            launchError = nil
            downloads.checkTransfers(reason: "avvio dell'app")
        } catch {
            services = nil
            launchError = .storage("The local library database could not be opened", location: nil, error: error)
        }
    }
}
