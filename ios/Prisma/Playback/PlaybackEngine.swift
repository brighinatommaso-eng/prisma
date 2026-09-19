import AVFoundation
import CoreMedia
import Foundation
import MediaPlayer
import Observation
import SwiftData
import UIKit

extension StoredTrack {
    /// Album order: by track number, unnumbered tracks last, then by title. The
    /// Library tab and the play queue both use it, so they cannot disagree.
    static func albumOrder(_ tracks: [StoredTrack]) -> [StoredTrack] {
        tracks.sorted {
            switch ($0.trackNo, $1.trackNo) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
            }
        }
    }
}

/// Plays downloaded tracks from Application Support/Music. Local files only:
/// nothing in playback touches the network, so it works in airplane mode.
///
/// Created once per process by `AppModel`, like `DownloadManager`, so the player,
/// the audio session, the remote commands and Now Playing outlive every view.
@Observable
final class PlaybackEngine {
    enum RepeatMode: String, CaseIterable, Identifiable {
        case off
        case all
        case one

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Ripeti disattivato"
            case .all: return "Ripeti la coda"
            case .one: return "Ripeti il brano"
            }
        }
    }

    /// Track ids in play order: album order, or shuffled when shuffle is on.
    private(set) var queue: [String] = []
    private(set) var currentIndex: Int?
    private(set) var isPlaying = false
    /// Seconds into the current track, updated twice a second.
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var shuffle = false
    private(set) var repeatMode: RepeatMode = .off
    /// The last playback failure, shown until dismissed.
    private(set) var lastError: APIError?
    /// What the engine did on its own: resumed, paused for a route change, restored.
    private(set) var message: String?
    /// Why the lock screen has no artwork, when a cover file exists but cannot be read.
    private(set) var artworkProblem: String?

    /// The queue before shuffling (album or playlist order), so turning shuffle off
    /// restores it.
    @ObservationIgnored private var albumOrder: [String] = []
    /// For each queue position, its position in `albumOrder`. Shuffle works on
    /// positions rather than track ids, because a playlist can hold the same track
    /// more than once.
    @ObservationIgnored private var queueSources: [Int] = []
    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let downloads: DownloadManager
    /// Which queue position each AVPlayerItem in the player plays. A position, not a
    /// track id, so a track that appears twice is still tracked correctly.
    @ObservationIgnored private var itemQueueIndices: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var notificationObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var commandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var timeObserver: Any?
    /// Whether the user wants audio: set by play and pause, cleared by
    /// interruptions and lost routes. Decides whether a track change keeps playing.
    @ObservationIgnored private var wantsToPlay = false
    @ObservationIgnored private var resumeAfterInterruption = false
    /// A position to apply once the current item is ready to play.
    @ObservationIgnored private var pendingSeek: TimeInterval?
    /// True while the engine itself replaces the player's items.
    @ObservationIgnored private var replacingItems = false
    @ObservationIgnored private var lastPersisted = Date.distantPast
    @ObservationIgnored private var artworkCache: (key: String, artwork: MPMediaItemArtwork)?

    private enum Key {
        static let queue = "playback.queue"
        static let albumOrder = "playback.albumOrder"
        static let index = "playback.index"
        static let position = "playback.position"
        static let shuffle = "playback.shuffle"
        static let repeatMode = "playback.repeatMode"
        static let queueSources = "playback.queueSources"
        static let all = [queue, albumOrder, index, position, shuffle, repeatMode, queueSources]
    }

    init(context: ModelContext, downloads: DownloadManager) {
        self.context = context
        self.downloads = downloads
        configureAudioSession()
        installObservers()
        installRemoteCommands()
        restore()
    }

    // MARK: - State for views

    var currentTrackID: String? {
        guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    var currentTrack: StoredTrack? {
        currentTrackID.flatMap { track(id: $0) }
    }

    var hasNext: Bool {
        nextIndex(after: currentIndex) != nil
    }

    // MARK: - Actions

    /// Plays `track` and queues the downloaded tracks after it in its album.
    func play(track: StoredTrack) {
        lastError = nil
        message = nil
        guard track.downloadState == .downloaded else {
            lastError = .invalidInput(
                "“\(track.title ?? track.serverID)” non è scaricato",
                detail: "Si possono riprodurre solo i brani salvati sul telefono: scaricalo prima."
            )
            return
        }
        // From the store, not from `album.tracks`: a to-many relationship is a
        // cache on the album, and after a deletion it can still name a track the
        // store no longer has, which would put a dead id in the queue.
        let albumTracks = track.album.map { album in
            StoredTrack.albumOrder(ModelLookup.members(of: album, in: context))
        } ?? [track]
        let start = albumTracks.firstIndex { $0.serverID == track.serverID } ?? 0
        var ids = albumTracks[start...].filter { $0.downloadState == .downloaded }.map(\.serverID)
        if ids.first != track.serverID {
            ids.insert(track.serverID, at: 0)
        }
        startQueue(ids, at: 0)
    }

    /// Plays a playlist: the queue is its downloaded tracks in playlist order, and
    /// playback starts at the entry at `startOffset` in `tracks`. Tracks that are not
    /// downloaded are left out. An offset rather than a track, because a playlist can
    /// hold the same track twice.
    func play(playlistTracks tracks: [StoredTrack], startingAt startOffset: Int) {
        lastError = nil
        message = nil
        guard tracks.indices.contains(startOffset) else {
            lastError = .invalidInput("Impossibile avviare la riproduzione", detail: "Il brano scelto non è più nell'elenco: riapri la schermata e riprova.")
            return
        }
        let start = tracks[startOffset]
        guard start.downloadState == .downloaded else {
            lastError = .invalidInput(
                "“\(start.title ?? start.serverID)” non è scaricato",
                detail: "Si possono riprodurre solo i brani salvati sul telefono: scaricalo prima."
            )
            return
        }
        var ids: [String] = []
        var startIndex: Int?
        // `tracks` was read from the store by the caller at the moment of the tap.
        for (offset, track) in tracks.enumerated() where track.downloadState == .downloaded {
            if offset == startOffset {
                startIndex = ids.count
            }
            ids.append(track.serverID)
        }
        guard let startIndex else {
            lastError = .invalidInput("Impossibile avviare la riproduzione", detail: "Il brano scelto non risulta tra quelli scaricati: controlla che sia scaricato e riprova.")
            return
        }
        startQueue(ids, at: startIndex)
    }

    /// Appends a downloaded track to the end of the queue, after anything shuffled.
    /// With nothing loaded it becomes the queue, paused: adding never starts
    /// playback by itself.
    func addToQueue(_ track: StoredTrack) {
        lastError = nil
        guard track.downloadState == .downloaded else {
            lastError = .invalidInput(
                "“\(track.title ?? track.serverID)” non è scaricato",
                detail: "Si possono mettere in coda solo i brani salvati sul telefono: scaricalo prima."
            )
            return
        }
        guard currentIndex != nil, !queue.isEmpty else {
            albumOrder = [track.serverID]
            queueSources = [0]
            queue = [track.serverID]
            load(index: 0, position: 0, autoplay: false)
            return
        }
        albumOrder.append(track.serverID)
        queueSources.append(albumOrder.count - 1)
        queue.append(track.serverID)
        preloadNext()
        updateNowPlaying()
        persist()
    }

    // MARK: - Used by LibrarySync

    /// Lets go of tracks that are about to leave the library, before their rows are
    /// deleted.
    ///
    /// The sync calls this while the rows still exist, so nothing in playback keeps
    /// pointing at a track the store no longer has: the queue holds ids that would
    /// stop resolving, and the mini player, the full player and Now Playing would go
    /// on showing a track that is gone until something else happened to make them
    /// render again. If one of the removed tracks is playing, playback moves to the
    /// next one still in the queue, or stops.
    func forget(trackIDs gone: Set<String>) {
        guard !gone.isEmpty else { return }
        guard queue.contains(where: { gone.contains($0) }) || albumOrder.contains(where: { gone.contains($0) }) else { return }

        let losingCurrent = currentTrackID.map { gone.contains($0) } ?? false
        let resume = wantsToPlay
        // Where the next surviving track ends up once the queue is rebuilt.
        let landing: Int
        if let index = currentIndex, queue.indices.contains(index) {
            landing = queue[..<index].filter { !gone.contains($0) }.count
        } else {
            landing = 0
        }

        var newAlbumOrder: [String] = []
        var moved: [Int: Int] = [:]
        for (position, id) in albumOrder.enumerated() where !gone.contains(id) {
            moved[position] = newAlbumOrder.count
            newAlbumOrder.append(id)
        }
        var newQueue: [String] = []
        var newSources: [Int] = []
        var survivingCurrent: Int?
        for (position, id) in queue.enumerated() where !gone.contains(id) {
            if let index = currentIndex, position == index {
                survivingCurrent = newQueue.count
            }
            let source: Int? = queueSources.indices.contains(position) ? moved[queueSources[position]] : nil
            newSources.append(source ?? newQueue.count)
            newQueue.append(id)
        }
        albumOrder = newAlbumOrder
        queueSources = newSources
        queue = newQueue

        guard !queue.isEmpty else {
            replacingItems = true
            player.removeAllItems()
            itemQueueIndices.removeAll()
            replacingItems = false
            wantsToPlay = false
            isPlaying = false
            currentIndex = nil
            elapsed = 0
            duration = 0
            message = "La coda si è svuotata: i brani che conteneva sono stati eliminati dal server."
            updateNowPlaying()
            persist()
            return
        }

        if losingCurrent {
            message = "Il brano in riproduzione è stato eliminato dal server: la riproduzione continua dal brano successivo della coda."
            load(index: min(landing, queue.count - 1), position: 0, autoplay: resume)
            return
        }

        currentIndex = survivingCurrent
        if let playing = player.currentItem, let survivingCurrent {
            // Only the item playing now keeps its place; the one preloaded after it
            // was queued for a position that has moved, so it is worked out again.
            itemQueueIndices = [ObjectIdentifier(playing): survivingCurrent]
            for item in player.items() where item !== playing {
                player.remove(item)
            }
        } else {
            itemQueueIndices.removeAll()
        }
        preloadNext()
        updateNowPlaying()
        persist()
    }

    /// Replaces the queue with `ids` and starts playing at `start`. With shuffle on,
    /// the starting track plays first and the rest follow in random order.
    private func startQueue(_ ids: [String], at start: Int) {
        albumOrder = ids
        if shuffle {
            queueSources = [start] + ids.indices.filter { $0 != start }.shuffled()
            queue = queueSources.map { ids[$0] }
            load(index: 0, position: 0, autoplay: true)
        } else {
            queueSources = Array(ids.indices)
            queue = ids
            load(index: start, position: 0, autoplay: true)
        }
    }

    func play() {
        guard player.currentItem != nil else {
            if let currentIndex {
                load(index: currentIndex, position: elapsed, autoplay: true)
            } else {
                message = "Non c'è niente da riprodurre: tocca un brano scaricato in Libreria."
            }
            return
        }
        // Must be active before audio starts, or playback stops on screen lock and
        // follows the ringer switch.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            report("Playback could not start: the audio session could not be activated", error: error,
                   message: "La riproduzione non è partita perché iOS non ha concesso l'audio: chiudi le altre app che stanno suonando o chiamando, poi riprova.")
            return
        }
        wantsToPlay = true
        player.play()
        updateNowPlaying()
        persist()
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        updateNowPlaying()
        persist()
    }

    func togglePlayPause() {
        if isPlaying || wantsToPlay {
            pause()
        } else {
            play()
        }
    }

    @discardableResult
    func next() -> Bool {
        guard let index = nextIndex(after: currentIndex) else {
            message = "Questo è l'ultimo brano della coda."
            return false
        }
        load(index: index, position: 0, autoplay: wantsToPlay)
        return true
    }

    /// Restarts the track after its first three seconds, as music apps do;
    /// otherwise goes to the previous track.
    @discardableResult
    func previous() -> Bool {
        guard currentIndex != nil else { return false }
        if currentPosition > 3 {
            seek(to: 0)
            return true
        }
        guard let index = previousIndex(before: currentIndex) else {
            seek(to: 0)
            return true
        }
        load(index: index, position: 0, autoplay: wantsToPlay)
        return true
    }

    func seek(to seconds: TimeInterval) {
        guard let item = player.currentItem else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        if item.status == .readyToPlay {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            pendingSeek = target
        }
        elapsed = target
        updateNowPlaying(position: target)
        persist()
    }

    func setShuffle(_ enabled: Bool) {
        guard enabled != shuffle else { return }
        shuffle = enabled
        if let index = currentIndex, queueSources.indices.contains(index) {
            let source = queueSources[index]
            if enabled {
                queueSources = [source] + albumOrder.indices.filter { $0 != source }.shuffled()
                currentIndex = 0
            } else {
                queueSources = Array(albumOrder.indices)
                currentIndex = source
            }
            queue = queueSources.map { albumOrder[$0] }
            if let current = player.currentItem, let currentIndex {
                itemQueueIndices[ObjectIdentifier(current)] = currentIndex
            }
            preloadNext()
            updateNowPlaying()
        }
        persist()
    }

    func setRepeat(_ mode: RepeatMode) {
        guard mode != repeatMode else { return }
        repeatMode = mode
        preloadNext()
        updateNowPlaying()
        persist()
    }

    func clearError() {
        lastError = nil
    }

    func clearMessage() {
        message = nil
    }

    /// Saves the queue and position; called on every change and when the app
    /// goes to the background.
    func persist() {
        let defaults = UserDefaults.standard
        guard let currentIndex, !queue.isEmpty else {
            for key in Key.all {
                defaults.removeObject(forKey: key)
            }
            return
        }
        defaults.set(queue, forKey: Key.queue)
        defaults.set(albumOrder, forKey: Key.albumOrder)
        defaults.set(queueSources, forKey: Key.queueSources)
        defaults.set(currentIndex, forKey: Key.index)
        defaults.set(currentPosition, forKey: Key.position)
        defaults.set(shuffle, forKey: Key.shuffle)
        defaults.set(repeatMode.rawValue, forKey: Key.repeatMode)
        lastPersisted = Date()
    }

    // MARK: - Loading items

    private enum Playable {
        case file(URL)
        case notDownloaded
        case unplayable(APIError)
    }

    private func playableFile(for track: StoredTrack) -> Playable {
        guard track.downloadState == .downloaded else { return .notDownloaded }
        let title = "Could not play “\(track.title ?? track.serverID)”"
        let marked = "The track was marked failed (file missing). Download it again from the Library tab."
        let missing = "Impossibile riprodurre “\(track.title ?? track.serverID)”: il file audio non è più sul telefono, quindi il brano è segnato come da riscaricare. Scaricalo di nuovo."
        guard let fileName = track.fileName else {
            return .unplayable(APIError(
                kind: .storage, title: title, url: nil,
                details: ["The track is marked downloaded but no file name is recorded for it.", marked],
                message: missing
            ))
        }
        let url: URL
        do {
            url = try LocalFiles.url(.music, fileName)
        } catch {
            return .unplayable(.storage(title, location: nil, error: error,
                                        message: "Impossibile raggiungere la cartella della musica sul telefono per riprodurre “\(track.title ?? track.serverID)”: riavvia l'app; se si ripete, controlla lo spazio libero."))
        }
        guard LocalFiles.exists(url) else {
            return .unplayable(APIError(
                kind: .storage, title: title, url: url.path(percentEncoded: false),
                details: ["The audio file is not on this iPhone.", marked],
                message: missing
            ))
        }
        return .file(url)
    }

    /// Replaces the player's items with the track at `index`, skipping forward past
    /// tracks that are not downloaded or whose file is missing.
    private func load(index: Int, position: TimeInterval, autoplay: Bool) {
        replacingItems = true
        player.removeAllItems()
        itemQueueIndices.removeAll()
        replacingItems = false
        pendingSeek = nil

        var candidate: Int? = queue.indices.contains(index) ? index : nil
        var tried = 0
        while let target = candidate, tried < queue.count {
            tried += 1
            guard let track = track(id: queue[target]) else {
                candidate = nextIndex(after: target)
                continue
            }
            switch playableFile(for: track) {
            case .file(let url):
                let item = AVPlayerItem(url: url)
                itemQueueIndices[ObjectIdentifier(item)] = target
                currentIndex = target
                duration = Double(track.durationS ?? 0)
                elapsed = target == index ? position : 0
                pendingSeek = elapsed > 0 ? elapsed : nil
                player.insert(item, after: nil)
                preloadNext()
                if autoplay {
                    play()
                } else {
                    wantsToPlay = false
                    updateNowPlaying()
                    persist()
                }
                return
            case .notDownloaded:
                candidate = nextIndex(after: target)
            case .unplayable(let error):
                recordUnplayable(track, error: error)
                candidate = nextIndex(after: target)
            }
        }

        wantsToPlay = false
        isPlaying = false
        currentIndex = nil
        message = "Nella coda non resta niente da riprodurre: i brani successivi non sono scaricati o i loro file mancano."
        updateNowPlaying()
        persist()
    }

    /// Keeps exactly one upcoming item after the current one, so AVQueuePlayer
    /// moves to the next track without a gap, including with the screen locked.
    private func preloadNext() {
        guard let current = player.currentItem, let index = currentIndex else {
            updateCommands()
            return
        }
        player.actionAtItemEnd = repeatMode == .one ? .pause : .advance
        let upcoming = player.items().filter { $0 !== current }

        var wanted: (index: Int, url: URL)?
        if repeatMode != .one {
            var candidate = nextIndex(after: index)
            var tried = 0
            while let target = candidate, tried < queue.count {
                tried += 1
                guard let track = track(id: queue[target]) else {
                    candidate = nextIndex(after: target)
                    continue
                }
                switch playableFile(for: track) {
                case .file(let url):
                    wanted = (index: target, url: url)
                case .notDownloaded:
                    break
                case .unplayable(let error):
                    recordUnplayable(track, error: error)
                }
                if wanted != nil { break }
                candidate = nextIndex(after: target)
            }
        }

        if upcoming.count == 1, let only = upcoming.first, let wanted,
           itemQueueIndices[ObjectIdentifier(only)] == wanted.index {
            updateCommands()
            return
        }
        for item in upcoming {
            player.remove(item)
            itemQueueIndices[ObjectIdentifier(item)] = nil
        }
        if let wanted {
            let item = AVPlayerItem(url: wanted.url)
            itemQueueIndices[ObjectIdentifier(item)] = wanted.index
            player.insert(item, after: current)
        }
        updateCommands()
    }

    private func recordUnplayable(_ track: StoredTrack, error: APIError) {
        downloads.recordUnplayableFile(track, error: error)
        lastError = error
    }

    // MARK: - Player events

    private func installObservers() {
        observations.append(PlaybackBridge.observe(player, \.currentItem) { [self] in
            currentItemChanged()
        })
        observations.append(PlaybackBridge.observe(player, \.currentItem?.status) { [self] in
            currentItemStatusChanged()
        })
        observations.append(PlaybackBridge.observe(player, \.timeControlStatus) { [self] in
            timeControlStatusChanged()
        })
        timeObserver = PlaybackBridge.addPeriodicObserver(player) { [self] seconds in
            tick(seconds)
        }

        let session = AVAudioSession.sharedInstance()
        notificationObservers = [
            PlaybackBridge.observe(AVAudioSession.interruptionNotification, object: session) { [self] notification in
                handleInterruption(notification)
            },
            PlaybackBridge.observe(AVAudioSession.routeChangeNotification, object: session) { [self] notification in
                handleRouteChange(notification)
            },
            PlaybackBridge.observe(AVAudioSession.mediaServicesWereResetNotification, object: session) { [self] _ in
                handleMediaServicesReset()
            },
            PlaybackBridge.observe(AVPlayerItem.didPlayToEndTimeNotification, object: nil) { [self] notification in
                itemDidPlayToEnd(notification)
            },
            PlaybackBridge.observe(AVPlayerItem.failedToPlayToEndTimeNotification, object: nil) { [self] notification in
                guard let item = notification.object as? AVPlayerItem else { return }
                itemFailed(item, error: notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)
            },
        ]
    }

    private func currentItemChanged() {
        guard !replacingItems else { return }
        guard let item = player.currentItem else {
            queueEnded()
            return
        }
        guard let index = itemQueueIndices[ObjectIdentifier(item)], queue.indices.contains(index) else {
            report("The player moved to an item Prisma did not queue", error: nil,
                   message: "Il lettore è passato a un brano che l'app non aveva messo in coda: tocca un brano per ripartire.")
            return
        }
        let previousIndex = currentIndex
        currentIndex = index
        let live = Set(player.items().map { ObjectIdentifier($0) })
        itemQueueIndices = itemQueueIndices.filter { live.contains($0.key) }
        if previousIndex != index {
            elapsed = 0
            duration = Double(currentTrack?.durationS ?? 0)
        }
        preloadNext()
        updateNowPlaying()
        persist()
    }

    private func currentItemStatusChanged() {
        guard let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            let seconds = item.duration.seconds
            if seconds.isFinite, seconds > 0 {
                duration = seconds
            }
            if let target = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                updateNowPlaying(position: target)
            } else {
                updateNowPlaying()
            }
        case .failed:
            itemFailed(item, error: item.error)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func timeControlStatusChanged() {
        let playing = player.timeControlStatus != .paused
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateNowPlaying()
        if !playing {
            persist()
        }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, pendingSeek == nil, player.currentItem != nil else { return }
        elapsed = seconds
        if isPlaying, Date().timeIntervalSince(lastPersisted) > 5 {
            persist()
        }
    }

    /// With repeat-one the player pauses at the end instead of advancing.
    private func itemDidPlayToEnd(_ notification: Notification) {
        guard repeatMode == .one, let item = notification.object as? AVPlayerItem, item === player.currentItem else { return }
        player.seek(to: .zero)
        elapsed = 0
        if wantsToPlay {
            player.play()
        }
        updateNowPlaying(position: 0)
    }

    /// The last item finished with repeat off: stay on it, paused at the start.
    private func queueEnded() {
        wantsToPlay = false
        isPlaying = false
        guard let index = currentIndex else {
            updateNowPlaying()
            return
        }
        message = "La coda è finita."
        load(index: index, position: 0, autoplay: false)
    }

    /// The file could not be decoded or read. Recorded on the track, shown, and
    /// playback moves on to the next track.
    private func itemFailed(_ item: AVPlayerItem, error: Error?) {
        guard let failedIndex = itemQueueIndices[ObjectIdentifier(item)], queue.indices.contains(failedIndex) else { return }
        let trackID = queue[failedIndex]
        let track = self.track(id: trackID)
        let resume = wantsToPlay
        let title = "Could not play “\(track?.title ?? trackID)”"
        var details: [String] = []
        if let error {
            let nsError = error as NSError
            details.append("AVFoundation error: \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
            if let reason = nsError.localizedFailureReason {
                details.append("Reason: \(reason)")
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                details.append("Underlying: \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)")
            }
        } else {
            details.append("AVFoundation reported a failure without an error.")
        }
        let path = (item.asset as? AVURLAsset)?.url.path(percentEncoded: false)

        if let track, track.downloadState == .downloaded {
            details.append("The audio file is missing or unreadable, so the track was marked failed (file missing). Download it again from the Library tab.")
            recordUnplayable(track, error: APIError(
                kind: .storage, title: title, url: path, details: details,
                message: "Impossibile riprodurre “\(track.title ?? trackID)”: il file audio manca o è danneggiato, quindi il brano è segnato come da riscaricare. Scaricalo di nuovo."
            ))
        } else {
            details.append("The track is no longer downloaded on this iPhone; it was removed or re-synced during playback.")
            lastError = APIError(
                kind: .storage, title: title, url: path, details: details,
                message: "Impossibile riprodurre “\(track?.title ?? trackID)”: il brano è stato rimosso dal telefono o risincronizzato durante la riproduzione. Scaricalo di nuovo."
            )
        }

        guard let next = nextIndex(after: failedIndex) else {
            replacingItems = true
            player.removeAllItems()
            itemQueueIndices.removeAll()
            replacingItems = false
            wantsToPlay = false
            isPlaying = false
            currentIndex = nil
            updateNowPlaying()
            persist()
            return
        }
        load(index: next, position: 0, autoplay: resume)
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        do {
            // .playback: keeps playing with the screen locked and ignores the ringer switch.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch {
            report("The audio session could not be set up for music playback", error: error,
                   message: "iOS non ha preparato l'audio per la musica: la riproduzione potrebbe fermarsi a schermo bloccato. Riavvia l'app.")
        }
    }

    /// A phone call or another app's audio: pause, and resume afterwards if iOS says so.
    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            report("iOS sent an audio interruption notification that could not be read", error: nil,
                   message: "iOS ha segnalato un'interruzione dell'audio che l'app non ha capito: se la musica si è fermata, tocca Riproduci.")
            return
        }
        switch type {
        case .began:
            // Reason 1 (appWasSuspended): a stale notice for an app that was
            // suspended; nothing was playing to interrupt.
            if let reason = info[AVAudioSessionInterruptionReasonKey] as? UInt, reason == 1 {
                return
            }
            resumeAfterInterruption = wantsToPlay
            wantsToPlay = false
            if resumeAfterInterruption {
                message = "In pausa dalle \(Formatting.time(Date())) per un'interruzione, per esempio una chiamata."
            }
            updateNowPlaying()
            persist()
        case .ended:
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            let options = AVAudioSession.InterruptionOptions(rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume) {
                message = "Ripresa alle \(Formatting.time(Date())) dopo un'interruzione."
                play()
            } else {
                message = "L'interruzione è finita, ma iOS non ha permesso di riprendere da sola: tocca Riproduci per continuare."
            }
        @unknown default:
            break
        }
    }

    /// Headphones unplugged or Bluetooth lost: pause rather than play from the speaker.
    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            report("iOS sent an audio route change notification that could not be read", error: nil,
                   message: "iOS ha segnalato un cambio di uscita audio che l'app non ha capito: se la musica si è fermata, tocca Riproduci.")
            return
        }
        guard reason == .oldDeviceUnavailable else { return }
        let wasPlaying = wantsToPlay || isPlaying
        pause()
        if wasPlaying {
            let previous = (info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                .outputs.map(\.portName).joined(separator: ", ")
            message = "In pausa dalle \(Formatting.time(Date())) perché l'uscita audio (\(previous ?? "sconosciuta")) si è scollegata."
        }
    }

    private func handleMediaServicesReset() {
        configureAudioSession()
        wantsToPlay = false
        message = "iOS ha riavviato i servizi audio e la riproduzione si è fermata: tocca Riproduci per continuare."
        if let index = currentIndex {
            load(index: index, position: elapsed, autoplay: false)
        }
    }

    // MARK: - Remote commands and Now Playing

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        register(center.playCommand) { [self] _ in
            guard currentIndex != nil else { return .noActionableNowPlayingItem }
            play()
            return .success
        }
        register(center.pauseCommand) { [self] _ in
            pause()
            return .success
        }
        register(center.togglePlayPauseCommand) { [self] _ in
            guard currentIndex != nil else { return .noActionableNowPlayingItem }
            togglePlayPause()
            return .success
        }
        register(center.nextTrackCommand) { [self] _ in
            next() ? .success : .noSuchContent
        }
        register(center.previousTrackCommand) { [self] _ in
            previous() ? .success : .noSuchContent
        }
        register(center.changePlaybackPositionCommand) { [self] position in
            guard let position, currentIndex != nil else { return .commandFailed }
            seek(to: position)
            return .success
        }
        // Otherwise the lock screen may show 15-second skip buttons instead of
        // previous and next.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
    }

    private func register(
        _ command: MPRemoteCommand,
        _ handler: @escaping @MainActor @Sendable (TimeInterval?) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        commandTargets.append((command, PlaybackBridge.addTarget(command, handler)))
    }

    private func updateCommands() {
        let center = MPRemoteCommandCenter.shared()
        let loaded = currentIndex != nil
        center.nextTrackCommand.isEnabled = hasNext
        center.previousTrackCommand.isEnabled = loaded
        center.changePlaybackPositionCommand.isEnabled = loaded
    }

    private func updateNowPlaying(position: TimeInterval? = nil) {
        updateCommands()
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title ?? "(no title)",
            MPMediaItemPropertyArtist: track.album?.artist ?? "",
            MPMediaItemPropertyAlbumTitle: track.album?.title ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position ?? currentPosition,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let currentIndex {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        }
        if let artwork = artwork(for: track) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
    }

    /// The album cover from Application Support/Artwork, never from the network.
    private func artwork(for track: StoredTrack) -> MPMediaItemArtwork? {
        guard let album = track.album, let fileName = album.coverFileName else {
            artworkProblem = nil
            return nil
        }
        let key = fileName + "|" + String(album.coverSavedAt?.timeIntervalSince1970 ?? 0)
        if let artworkCache, artworkCache.key == key {
            return artworkCache.artwork
        }
        do {
            let url = try LocalFiles.url(.artwork, fileName)
            guard let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) else {
                artworkProblem = "Il file della copertina manca o è illeggibile, quindi la schermata di blocco non la mostra: sincronizza la libreria per riscaricarla."
                return nil
            }
            let artwork = PlaybackBridge.artwork(image)
            artworkCache = (key: key, artwork: artwork)
            artworkProblem = nil
            return artwork
        } catch {
            artworkProblem = "La copertina non si è potuta leggere: sincronizza la libreria per riscaricarla."
            return nil
        }
    }

    // MARK: - Restore

    /// Brings back the last queue and position, paused. Nothing plays until asked.
    private func restore() {
        let defaults = UserDefaults.standard
        guard let savedQueue = defaults.stringArray(forKey: Key.queue), !savedQueue.isEmpty else { return }
        let index = defaults.integer(forKey: Key.index)
        guard savedQueue.indices.contains(index) else {
            message = "La posizione di ascolto salvata non corrispondeva alla coda salvata ed è stata scartata: tocca un brano per ricominciare."
            for key in Key.all {
                defaults.removeObject(forKey: key)
            }
            return
        }
        queue = savedQueue
        albumOrder = defaults.stringArray(forKey: Key.albumOrder) ?? savedQueue
        queueSources = Self.sources(
            saved: defaults.array(forKey: Key.queueSources) as? [Int],
            queue: savedQueue,
            order: albumOrder
        )
        shuffle = defaults.bool(forKey: Key.shuffle)
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Key.repeatMode) ?? "") ?? .off
        let position = defaults.double(forKey: Key.position)
        load(index: index, position: position, autoplay: false)
        if let track = currentTrack {
            let at = currentIndex == index ? "da \(Formatting.clock(position))" : "dall'inizio"
            message = "Ripristinato “\(track.title ?? track.serverID)” \(at), in pausa."
        }
    }

    // MARK: - Helpers

    /// Saved source positions if they are consistent with the queue; otherwise
    /// rebuilt by matching each queue entry to the next unused occurrence in
    /// `order` (older saves have none).
    private static func sources(saved: [Int]?, queue: [String], order: [String]) -> [Int] {
        if let saved, saved.count == queue.count,
           saved.allSatisfy({ order.indices.contains($0) }),
           zip(saved, queue).allSatisfy({ order[$0.0] == $0.1 }) {
            return saved
        }
        var used = Set<Int>()
        var result: [Int] = []
        for id in queue {
            if let match = order.indices.first(where: { !used.contains($0) && order[$0] == id }) {
                used.insert(match)
                result.append(match)
            } else {
                result.append(0)
            }
        }
        return result
    }

    private var currentPosition: TimeInterval {
        if let pendingSeek { return pendingSeek }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : elapsed
    }

    private func nextIndex(after index: Int?) -> Int? {
        guard let index, !queue.isEmpty else { return nil }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }

    private func previousIndex(before index: Int?) -> Int? {
        guard let index, !queue.isEmpty else { return nil }
        if index > 0 { return index - 1 }
        return repeatMode == .all && queue.count > 1 ? queue.count - 1 : nil
    }

    private func track(id: String) -> StoredTrack? {
        var descriptor = FetchDescriptor<StoredTrack>(predicate: #Predicate<StoredTrack> { $0.serverID == id })
        descriptor.fetchLimit = 1
        do {
            return try context.fetch(descriptor).first
        } catch {
            report("Could not read track \(id) from the local library", error: error,
                   message: "Impossibile leggere un brano dalla libreria sul telefono: riavvia l'app; se si ripete, controlla lo spazio libero.")
            return nil
        }
    }

    /// `message` is the Italian sentence shown to the user.
    private func report(_ title: String, error: Error?, message userMessage: String) {
        var details: [String] = []
        if let error {
            let nsError = error as NSError
            details.append("\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
            details.append("Debug: \(String(describing: error))")
        }
        lastError = APIError(kind: .unexpected, title: title, url: nil, details: details, message: userMessage)
    }
}
