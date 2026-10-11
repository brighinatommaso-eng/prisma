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
        let reachability: ServerReachability
        let sync: LibrarySync
        let playback: PlaybackEngine
        let theme: ThemeEngine
        let playlists: PlaylistStore
        let acquisitions: AcquisitionCoordinator
        let deletion: TrackDeletion
        let collection: CollectionSync
        let importer: DemusImporter
    }

    let settings: AppSettings
    /// nil only when the database could not be opened; `launchError` says why.
    let services: Services?
    let launchError: APIError?

    private init() {
        let settings = AppSettings()
        self.settings = settings
        do {
            // FavouriteTrack and PlaylistImport are new entities and the fields added
            // to StoredTrack, SyncRecord and PendingAcquisition are optional or carry
            // a default, so the library already on the phone opens with a
            // lightweight migration and nothing in it is rewritten.
            let container = try ModelContainer(
                for: StoredAlbum.self, StoredTrack.self, SyncRecord.self,
                Playlist.self, PlaylistEntry.self, PendingAcquisition.self, FavouriteTrack.self,
                PlaylistImport.self
            )
            let downloads = DownloadManager(context: container.mainContext, settings: settings)
            let sync = LibrarySync(context: container.mainContext, settings: settings, downloads: downloads)
            let reachability = ServerReachability(settings: settings)
            let collection = CollectionSync(context: container.mainContext, settings: settings, reachability: reachability)
            settings.onAddressChange = { [downloads, reachability, collection] previous, new in
                downloads.serverAddressChanged(from: previous, to: new)
                // The recorded answer was about a different server.
                reachability.addressChanged()
                // The same server by another name: nothing the collection remembers
                // is dropped, but a pass in flight must not write what the old
                // client hears back.
                collection.addressChanged()
            }
            let playback = PlaybackEngine(
                context: container.mainContext, settings: settings,
                downloads: downloads, reachability: reachability
            )
            sync.playback = playback
            let theme = ThemeEngine(playback: playback)
            let playlists = PlaylistStore(context: container.mainContext, downloads: downloads, playback: playback)
            playlists.onCollectionChange = { [collection] in collection.localChanged() }
            // Created here but idle: it only runs once RootView reports the app is
            // in the foreground, never during a background launch.
            let acquisitions = AcquisitionCoordinator(
                context: container.mainContext, settings: settings, sync: sync,
                downloads: downloads, playlists: playlists, reachability: reachability
            )
            // The single wire between "is the server there" and "what can play".
            // Only a real change arrives here, so a queue is never reconsidered
            // because a probe merely repeated itself.
            reachability.onChange = { [playback, collection, acquisitions] reachable in
                playback.serverReachabilityChanged(reachable: reachable)
                // Changes made while the server was away are pushed now, and the
                // acquisitions left where they were go on from there. Not a retry
                // timer: this is the server coming back.
                if reachable {
                    collection.serverBecameReachable()
                    acquisitions.serverBecameReachable()
                }
            }
            // Starts the network-path watch, whose first update is the first probe
            // of the process. Nothing here repeats on a schedule. Started only now,
            // with everything the wire above reaches in existence.
            reachability.start()
            let deletion = TrackDeletion(context: container.mainContext, settings: settings, sync: sync)
            // Idle until a file arrives. It writes through the two services above, so
            // an import is the same playlist change and the same acquisitions a hand
            // would have made, fifty at a time.
            let importer = DemusImporter(
                context: container.mainContext, settings: settings, playlists: playlists,
                acquisitions: acquisitions, downloads: downloads
            )
            services = Services(container: container, downloads: downloads, reachability: reachability, sync: sync, playback: playback, theme: theme, playlists: playlists, acquisitions: acquisitions, deletion: deletion, collection: collection, importer: importer)
            playlists.removeOrphanedEntries()
            // Preferiti is now the only place a track is browsed, so everything
            // already on this phone becomes a favourite once. Runs before any view
            // exists, and does nothing on every launch after the first.
            playlists.migrateFavourites()
            launchError = nil
            downloads.checkTransfers(reason: "avvio dell'app")
        } catch {
            services = nil
            launchError = .storage("The local library database could not be opened", location: nil, error: error)
        }
    }
}
