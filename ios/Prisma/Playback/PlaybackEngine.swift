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

/// Plays a track from the file in Application Support/Music when the phone has one,
/// and straight from the server when it does not.
///
/// The file always wins: a downloaded track plays locally even with the server one
/// hop away, because that is faster and costs no data, and it is what makes the app
/// work unchanged in airplane mode. Streaming exists for the other case — a track
/// the server has and this phone has not — and it is the same playback in every
/// other respect. One `AVQueuePlayer`, one audio session, one Now Playing centre,
/// one set of remote commands: the choice between a file and a stream is made in
/// `source(for:)` and shows up nowhere else, so the lock screen cannot behave
/// differently for the two.
///
/// Streaming depends on something that can disappear while it is happening, which
/// local playback does not. Three things follow from that, and they are the only
/// places the two paths differ:
///
/// - The queue is built from what can play *now*, and rebuilt — without losing its
///   ids — whenever that changes. `ServerReachability` tells the engine; the engine
///   never asks on the main path.
/// - A stream that has not produced audio within `streamDeadline` is declared
///   failed and playback moves on. There is no state in which the app waits forever
///   for a server that has gone quiet.
/// - Nothing streamed is written to disk. `AVPlayerItem` over HTTP buffers in
///   memory and discards what it has played; downloading stays an explicit act.
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
    /// The current track is coming from the server rather than from a file here.
    private(set) var isStreaming = false
    /// A stream is waiting for audio. Always bounded: `streamWatchdog` ends it one
    /// way or the other within `streamDeadline`, so this can never be a spinner that
    /// stays up.
    private(set) var isBuffering = false

    /// How long a stream may go without producing audio before it is declared
    /// failed: from the moment it is asked to play, and again from every stall.
    ///
    /// It is a deadline, not a poll — one sleep, armed by an event, cancelled the
    /// moment the player reports it is playing.
    static let streamDeadline: TimeInterval = 15

    /// The queue before shuffling (album or playlist order), so turning shuffle off
    /// restores it.
    @ObservationIgnored private var albumOrder: [String] = []
    /// For each queue position, its position in `albumOrder`. Shuffle works on
    /// positions rather than track ids, because a playlist can hold the same track
    /// more than once.
    @ObservationIgnored private var queueSources: [Int] = []
    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private let context: ModelContext
    /// Only to build the URL a stream is read from, and to say so when there is no
    /// address to build one out of.
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let downloads: DownloadManager
    @ObservationIgnored private let reachability: ServerReachability
    /// What each AVPlayerItem in the player is playing: its queue position — a
    /// position, not a track id, so a track that appears twice is still tracked
    /// correctly — and whether it came from the server. The second half is why
    /// `itemFailed` can tell a missing local file from a stream that dropped, and
    /// mark the track failed only in the first case.
    @ObservationIgnored private var itemQueueIndices: [ObjectIdentifier: QueuedItem] = [:]
    /// The next queue position that can play right now, worked out with the upcoming
    /// item and kept, so `hasNext` and the lock screen's next button can answer
    /// without walking the queue and fetching every track again.
    @ObservationIgnored private var nextPlayable: Int?
    @ObservationIgnored private var streamWatchdog: Task<Void, Never>?
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

    /// One AVPlayerItem's place in the queue, and where its audio comes from.
    private struct QueuedItem {
        let index: Int
        let isStream: Bool
    }

    init(
        context: ModelContext,
        settings: AppSettings,
        downloads: DownloadManager,
        reachability: ServerReachability
    ) {
        self.context = context
        self.settings = settings
        self.downloads = downloads
        self.reachability = reachability
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
        nextPlayable != nil
    }

    // MARK: - What can play right now

    /// The one rule the whole feature rests on.
    ///
    /// 1. The file is on this phone → it plays, from the file, even with the server
    ///    one hop away.
    /// 2. No file, and the server both has the track and is answering → it streams.
    /// 3. Otherwise it cannot play now, and whatever asked says so instead of
    ///    starting something that would hang.
    ///
    /// "The server has the track" is `serverDroppedAt == nil`: a copy this phone
    /// claimed as its only one, and a favourite the server never heard of, have no
    /// file at `/tracks/{id}/file` to stream. "The server is answering" is the last
    /// answer `ServerReachability` recorded; before the first probe of a session it
    /// counts as yes, because attempting is the fastest way to find out and the
    /// attempt is bounded by `streamDeadline`.
    func canPlayNow(_ track: StoredTrack) -> Bool {
        if track.downloadState == .downloaded { return true }
        return canStream(track)
    }

    private func canStream(_ track: StoredTrack) -> Bool {
        track.downloadState != .downloaded
            && track.serverDroppedAt == nil
            && reachability.mayStream
            && !settings.savedAddress.isEmpty
    }

    /// Why a track will not play, as the sentence the user reads.
    private func cannotPlay(_ track: StoredTrack) -> APIError {
        let name = track.title ?? track.serverID
        if track.serverDroppedAt != nil {
            return .invalidInput(
                "“\(name)” non è più sul server e non è sul telefono",
                detail: "Il file di questo brano non esiste da nessuna parte: fallo riscaricare dal server dai Preferiti per poterlo ascoltare."
            )
        }
        if settings.savedAddress.isEmpty {
            return .invalidInput(
                "“\(name)” è solo sul server, e non c'è un indirizzo del server",
                detail: "Imposta l'indirizzo in Impostazioni per riprodurlo in streaming, oppure scaricalo sul telefono."
            )
        }
        return .invalidInput(
            "“\(name)” è solo sul server, che ora non risponde",
            detail: "Senza server non si può riprodurre in streaming: controlla la rete e, se lo usi, che Tailscale sia connesso, poi riprova. I brani scaricati sul telefono si ascoltano comunque."
        )
    }

    // MARK: - Actions

    /// Plays `track` and queues the playable tracks after it in its album.
    func play(track: StoredTrack) {
        lastError = nil
        message = nil
        guard canPlayNow(track) else {
            lastError = cannotPlay(track)
            return
        }
        // From the store, not from `album.tracks`: a to-many relationship is a
        // cache on the album, and after a deletion it can still name a track the
        // store no longer has, which would put a dead id in the queue.
        let albumTracks = track.album.map { album in
            StoredTrack.albumOrder(ModelLookup.members(of: album, in: context))
        } ?? [track]
        let start = albumTracks.firstIndex { $0.serverID == track.serverID } ?? 0
        var ids = albumTracks[start...].filter { canPlayNow($0) }.map(\.serverID)
        if ids.first != track.serverID {
            ids.insert(track.serverID, at: 0)
        }
        startQueue(ids, at: 0)
    }

    /// Plays a playlist: the queue is the tracks that can play now, in playlist
    /// order, and playback starts at the entry at `startOffset` in `tracks`. An
    /// offset rather than a track, because a playlist can hold the same track twice.
    ///
    /// Built from availability at the moment of the tap, which for a streamed track
    /// means "the server was answering then". If that stops being true the queue is
    /// worked out again rather than rebuilt: see `serverReachabilityChanged`.
    func play(playlistTracks tracks: [StoredTrack], startingAt startOffset: Int) {
        lastError = nil
        message = nil
        guard tracks.indices.contains(startOffset) else {
            lastError = .invalidInput("Impossibile avviare la riproduzione", detail: "Il brano scelto non è più nell'elenco: riapri la schermata e riprova.")
            return
        }
        let start = tracks[startOffset]
        guard canPlayNow(start) else {
            lastError = cannotPlay(start)
            return
        }
        var ids: [String] = []
        var startIndex: Int?
        // `tracks` was read from the store by the caller at the moment of the tap.
        for (offset, track) in tracks.enumerated() where canPlayNow(track) {
            if offset == startOffset {
                startIndex = ids.count
            }
            ids.append(track.serverID)
        }
        guard let startIndex else {
            lastError = .invalidInput("Impossibile avviare la riproduzione", detail: "Il brano scelto non risulta tra quelli riproducibili adesso: scaricalo sul telefono, oppure riprova quando il server risponde.")
            return
        }
        startQueue(ids, at: startIndex)
    }

    /// Appends a track that can play now to the end of the queue, after anything
    /// shuffled. With nothing loaded it becomes the queue, paused: adding never
    /// starts playback by itself.
    func addToQueue(_ track: StoredTrack) {
        lastError = nil
        guard canPlayNow(track) else {
            lastError = cannotPlay(track)
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
            stopCleanly(message: "La coda si è svuotata: i brani che conteneva sono stati eliminati dal server.")
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
            let wasStream = itemQueueIndices[ObjectIdentifier(playing)]?.isStream ?? false
            itemQueueIndices = [ObjectIdentifier(playing): QueuedItem(index: survivingCurrent, isStream: wasStream)]
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

    // MARK: - Used by ServerReachability

    /// The server appeared or went away. Called by `AppModel`'s wiring whenever the
    /// recorded answer actually changes, never on a repeat.
    ///
    /// The queue keeps its ids either way. A queue is a list of tracks the user
    /// asked for, not a list of tracks that happen to be reachable this second:
    /// rebuilding it would lose the order they chose, and the tracks would have to
    /// be found again when the server came back. What changes is which positions can
    /// produce audio, and that is worked out in `load` and `preloadNext`, which walk
    /// forward past anything `source(for:)` says is unavailable.
    ///
    /// So losing the server does three things, in this order:
    ///
    /// 1. If the current track is streaming, it stops — cleanly, not as a failure:
    ///    the player's items go, the position is not persisted as a half-second of
    ///    a stream, and playback continues from the next position that can still
    ///    play. That is a downloaded track, because nothing else can play with the
    ///    server gone. If it was playing, the next one plays; if it was paused, the
    ///    next one is loaded paused. If nothing in the queue is on the phone,
    ///    playback stops and Now Playing clears, with a sentence saying why.
    /// 2. If the current track is local, it is not touched at all — not a pause, not
    ///    a gap. Only the item preloaded after it may be a stream, so that one is
    ///    worked out again and becomes the next downloaded track instead.
    /// 3. Either way the lock screen follows, through the same `updateNowPlaying`
    ///    every other change goes through: the next button switches off when nothing
    ///    playable is left, and the title and artwork are the ones actually playing.
    ///
    /// The server coming back is the mirror image and much quieter: nothing that is
    /// playing is disturbed, the upcoming item is worked out again so a streamable
    /// track is available once more, and the user is told the queue is whole again.
    func serverReachabilityChanged(reachable: Bool) {
        guard currentIndex != nil, !queue.isEmpty else {
            nextPlayable = nil
            updateCommands()
            return
        }
        let streamsInQueue = queue.contains { id in
            guard let track = track(id: id) else { return false }
            return track.downloadState != .downloaded && track.serverDroppedAt == nil
        }
        guard streamsInQueue else { return }

        if reachable {
            preloadNext()
            updateNowPlaying()
            message = "Il server è di nuovo raggiungibile: i brani della coda che sono solo sul server tornano riproducibili."
            return
        }

        guard isStreaming, let index = currentIndex else {
            // A local track keeps playing untouched; only what comes after it has to
            // be chosen again.
            preloadNext()
            updateNowPlaying()
            message = "Il server non è più raggiungibile: la riproduzione continua, ma i brani della coda che sono solo sul server vengono saltati finché non torna."
            return
        }

        let name = currentTrack?.title ?? queue[index]
        let resume = wantsToPlay
        stopStreamedItems()
        guard let landing = nextPlayableIndex(after: index) else {
            stopCleanly(
                message: "“\(name)” era in streaming e il server non è più raggiungibile: la riproduzione si è fermata, perché nella coda non c'è nessun brano scaricato su questo telefono."
            )
            return
        }
        message = "“\(name)” era in streaming e il server non è più raggiungibile: la riproduzione continua dal primo brano della coda che è sul telefono."
        load(index: landing, position: 0, autoplay: resume)
    }

    /// Takes every streamed item out of the player without treating it as a failure.
    /// Playback is about to be moved, or stopped, on purpose.
    private func stopStreamedItems() {
        disarmStreamWatchdog()
        player.pause()
        replacingItems = true
        player.removeAllItems()
        itemQueueIndices.removeAll()
        replacingItems = false
        isStreaming = false
        isBuffering = false
        pendingSeek = nil
    }

    /// Nothing left to play: the player is emptied, the lock screen cleared, and the
    /// sentence explains it. Shared by every place playback runs out.
    private func stopCleanly(message text: String) {
        disarmStreamWatchdog()
        replacingItems = true
        player.removeAllItems()
        itemQueueIndices.removeAll()
        replacingItems = false
        wantsToPlay = false
        isPlaying = false
        isStreaming = false
        isBuffering = false
        currentIndex = nil
        elapsed = 0
        duration = 0
        nextPlayable = nil
        message = text
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
                message = "Non c'è niente da riprodurre: tocca un brano in Libreria."
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
        if isStreaming {
            // From here the server has `streamDeadline` seconds to produce audio.
            isBuffering = player.timeControlStatus != .playing
            armStreamWatchdog(reason: .starting)
        }
        updateNowPlaying()
        persist()
    }

    func pause() {
        wantsToPlay = false
        disarmStreamWatchdog()
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
        guard let index = nextPlayable else {
            message = reachability.isReachable == false && currentIndex != nil
                ? "Dopo questo non c'è altro da riprodurre adesso: i brani che restano nella coda sono solo sul server, che non è raggiungibile."
                : "Questo è l'ultimo brano della coda."
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
        guard let index = previousPlayableIndex(before: currentIndex) else {
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
        if isStreaming, wantsToPlay {
            // The server has to serve a new Range from here; the same deadline
            // applies to that as to starting.
            armStreamWatchdog(reason: .starting)
        }
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
                let wasStream = itemQueueIndices[ObjectIdentifier(current)]?.isStream ?? false
                itemQueueIndices[ObjectIdentifier(current)] = QueuedItem(index: currentIndex, isStream: wasStream)
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

    /// Where one track's audio comes from, decided in one place.
    private enum Source {
        /// A file in Application Support/Music.
        case file(URL)
        /// GET /tracks/{id}/file on the saved server address.
        case stream(URL)
        /// Not now: no file here and no file there, or the server is not answering.
        case unavailable
        /// The track says it is downloaded and its file is not readable. Recorded on
        /// the track so the row offers to download it again.
        case unplayable(APIError)

        /// The URL to play and whether it comes over the network, for the two cases
        /// that produce audio at all.
        var playable: (url: URL, isStream: Bool)? {
            switch self {
            case .file(let url): return (url, false)
            case .stream(let url): return (url, true)
            case .unavailable, .unplayable: return nil
            }
        }
    }

    /// The rule of `canPlayNow`, with the URL attached. The only code that decides
    /// between a file and a stream.
    private func source(for track: StoredTrack) -> Source {
        if track.downloadState == .downloaded {
            return localFile(for: track)
        }
        guard canStream(track) else { return .unavailable }
        do {
            let client = try settings.makeClient()
            return .stream(try client.trackFileURL(trackID: track.serverID))
        } catch {
            // Only an unusable saved address reaches here, and `canPlayNow` already
            // called it unplayable, so the row said so before the tap.
            return .unavailable
        }
    }

    private func localFile(for track: StoredTrack) -> Source {
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

    /// An `AVPlayerItem` for a source, and nothing more.
    ///
    /// A stream is a plain `AVPlayerItem` over HTTP. Nothing here uses
    /// `AVAssetDownloadURLSession` or an `AVAssetResourceLoaderDelegate`, which are
    /// the two ways AVFoundation writes media to disk, so what is streamed is
    /// buffered in memory and discarded — downloading a track stays something the
    /// user asks for, in Preferiti, with a destination.
    ///
    /// `preferPreciseDurationAndTiming` is off for a stream: it would make
    /// AVFoundation read more of the file up front to build an exact timing map, and
    /// the duration is already known from the library.
    private func makeItem(url: URL, isStream: Bool) -> AVPlayerItem {
        guard isStream else { return AVPlayerItem(url: url) }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        return AVPlayerItem(asset: asset)
    }

    /// Replaces the player's items with the track at `index`, skipping forward past
    /// tracks that cannot play now — not on the phone and not reachable on the
    /// server, or downloaded with a file that has gone.
    private func load(index: Int, position: TimeInterval, autoplay: Bool) {
        disarmStreamWatchdog()
        replacingItems = true
        player.removeAllItems()
        itemQueueIndices.removeAll()
        replacingItems = false
        pendingSeek = nil
        isBuffering = false

        var candidate: Int? = queue.indices.contains(index) ? index : nil
        var tried = 0
        while let target = candidate, tried < queue.count {
            tried += 1
            guard let track = track(id: queue[target]) else {
                candidate = nextIndex(after: target)
                continue
            }
            let source = self.source(for: track)
            if let playable = source.playable {
                let item = makeItem(url: playable.url, isStream: playable.isStream)
                itemQueueIndices[ObjectIdentifier(item)] = QueuedItem(index: target, isStream: playable.isStream)
                currentIndex = target
                isStreaming = playable.isStream
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
            }
            if case .unplayable(let error) = source {
                recordUnplayable(track, error: error)
            }
            candidate = nextIndex(after: target)
        }

        stopCleanly(message: nothingLeftMessage)
    }

    /// Why the queue ran out, told apart so the sentence is the true one.
    private var nothingLeftMessage: String {
        if settings.savedAddress.isEmpty {
            return "Nella coda non resta niente da riprodurre: i brani rimasti non sono sul telefono e non c'è un indirizzo del server da cui riprodurli in streaming — impostalo in Impostazioni."
        }
        if reachability.isReachable == false {
            return "Nella coda non resta niente da riprodurre adesso: i brani rimasti sono solo sul server, che non è raggiungibile."
        }
        return "Nella coda non resta niente da riprodurre: i brani successivi non sono scaricati o i loro file mancano."
    }

    /// The next position after `index` that can produce audio right now, or nil.
    /// Reads the store, so it is worked out once per change and kept in
    /// `nextPlayable` rather than asked on every draw.
    private func nextPlayableIndex(after index: Int) -> Int? {
        var candidate = nextIndex(after: index)
        var tried = 0
        while let target = candidate, tried < queue.count {
            tried += 1
            if let track = track(id: queue[target]), canPlayNow(track) {
                return target
            }
            candidate = nextIndex(after: target)
        }
        return nil
    }

    /// Keeps exactly one upcoming item after the current one, so AVQueuePlayer
    /// moves to the next track without a gap, including with the screen locked, and
    /// records which position that is so `hasNext` can answer honestly.
    ///
    /// A streamed track is preloaded the same way a local one is. AVFoundation
    /// starts filling its buffer as soon as the item is in the player, which is what
    /// makes a stream follow a track without a pause — and it is still only one item
    /// ahead, so a queue of streams never opens more than two connections.
    private func preloadNext() {
        guard let current = player.currentItem, let index = currentIndex else {
            nextPlayable = nil
            updateCommands()
            return
        }
        player.actionAtItemEnd = repeatMode == .one ? .pause : .advance
        let upcoming = player.items().filter { $0 !== current }

        var wanted: (index: Int, url: URL, isStream: Bool)?
        var candidate = nextIndex(after: index)
        var tried = 0
        while let target = candidate, tried < queue.count {
            tried += 1
            guard let track = track(id: queue[target]) else {
                candidate = nextIndex(after: target)
                continue
            }
            let source = self.source(for: track)
            if let playable = source.playable {
                wanted = (index: target, url: playable.url, isStream: playable.isStream)
                break
            }
            if case .unplayable(let error) = source {
                recordUnplayable(track, error: error)
            }
            candidate = nextIndex(after: target)
        }
        // What the next button may go to, whether or not it was preloaded: with
        // repeat-one nothing is queued after the current item, but next still works.
        nextPlayable = wanted?.index

        guard repeatMode != .one else {
            for item in upcoming {
                player.remove(item)
                itemQueueIndices[ObjectIdentifier(item)] = nil
            }
            updateCommands()
            return
        }

        if upcoming.count == 1, let only = upcoming.first, let wanted,
           itemQueueIndices[ObjectIdentifier(only)]?.index == wanted.index {
            updateCommands()
            return
        }
        for item in upcoming {
            player.remove(item)
            itemQueueIndices[ObjectIdentifier(item)] = nil
        }
        if let wanted {
            let item = makeItem(url: wanted.url, isStream: wanted.isStream)
            itemQueueIndices[ObjectIdentifier(item)] = QueuedItem(index: wanted.index, isStream: wanted.isStream)
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
            // A stream that ran dry mid-track. AVFoundation will keep trying
            // forever; the watchdog gives it `streamDeadline` and then moves on.
            PlaybackBridge.observe(AVPlayerItem.playbackStalledNotification, object: nil) { [self] notification in
                guard let item = notification.object as? AVPlayerItem, item === player.currentItem else { return }
                guard itemQueueIndices[ObjectIdentifier(item)]?.isStream == true else { return }
                isBuffering = true
                armStreamWatchdog(reason: .stalled)
            },
        ]
    }

    // MARK: - The streaming deadline

    /// Why a stream is being waited on, which decides the sentence if it runs out.
    private enum StreamWait {
        case starting
        case stalled
    }

    /// Gives the current stream `streamDeadline` seconds to produce audio.
    ///
    /// One sleep, armed by an event — asking a stream to play, or a stall — and
    /// cancelled the moment the player reports it is playing. It is what makes "no
    /// spinner that waits forever" true: every wait on the network ends in audio or
    /// in a sentence, inside fifteen seconds.
    private func armStreamWatchdog(reason: StreamWait) {
        guard let item = player.currentItem,
              itemQueueIndices[ObjectIdentifier(item)]?.isStream == true else {
            disarmStreamWatchdog()
            return
        }
        streamWatchdog?.cancel()
        let waiting = ObjectIdentifier(item)
        streamWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.streamDeadline))
            guard !Task.isCancelled, let self else { return }
            self.streamDeadlineExpired(for: waiting, reason: reason)
        }
    }

    private func disarmStreamWatchdog() {
        streamWatchdog?.cancel()
        streamWatchdog = nil
        isBuffering = false
    }

    /// The stream had its fifteen seconds. Say so and move on.
    private func streamDeadlineExpired(for waiting: ObjectIdentifier, reason: StreamWait) {
        guard let item = player.currentItem, ObjectIdentifier(item) == waiting else { return }
        guard let slot = itemQueueIndices[waiting], slot.isStream, queue.indices.contains(slot.index) else { return }
        guard player.timeControlStatus != .playing else {
            disarmStreamWatchdog()
            return
        }
        let trackID = queue[slot.index]
        let name = track(id: trackID)?.title ?? trackID
        let sentence: String
        switch reason {
        case .starting:
            sentence = "Lo streaming di “\(name)” non è partito: il server non ha mandato audio entro \(Int(Self.streamDeadline)) secondi."
        case .stalled:
            sentence = "Lo streaming di “\(name)” si è interrotto: il server ha smesso di mandare audio per \(Int(Self.streamDeadline)) secondi."
        }
        // The server disagreed with what was on file about it, so ask it again. The
        // answer, when it arrives, may take the rest of the queue's streams with it.
        reachability.streamingFailed()
        streamFailed(
            at: slot.index,
            error: APIError(
                kind: .transport,
                title: "Streaming stalled for “\(name)”",
                url: (item.asset as? AVURLAsset)?.url.absoluteString,
                details: [
                    "No audio for \(Int(Self.streamDeadline))s while \(reason == .starting ? "starting" : "playing").",
                    "AVPlayer timeControlStatus: \(player.timeControlStatus.rawValue).",
                    "AVPlayerItem isPlaybackLikelyToKeepUp: \(item.isPlaybackLikelyToKeepUp), isPlaybackBufferEmpty: \(item.isPlaybackBufferEmpty).",
                ],
                message: sentence + " Controlla la rete e, se lo usi, che Tailscale sia connesso; per ascoltarlo senza rete scaricalo sul telefono."
            )
        )
    }

    private func currentItemChanged() {
        guard !replacingItems else { return }
        guard let item = player.currentItem else {
            queueEnded()
            return
        }
        guard let slot = itemQueueIndices[ObjectIdentifier(item)], queue.indices.contains(slot.index) else {
            report("The player moved to an item Prisma did not queue", error: nil,
                   message: "Il lettore è passato a un brano che l'app non aveva messo in coda: tocca un brano per ripartire.")
            return
        }
        let previousIndex = currentIndex
        currentIndex = slot.index
        isStreaming = slot.isStream
        let live = Set(player.items().map { ObjectIdentifier($0) })
        itemQueueIndices = itemQueueIndices.filter { live.contains($0.key) }
        if previousIndex != slot.index {
            elapsed = 0
            duration = Double(currentTrack?.durationS ?? 0)
        }
        // The queue player moved on by itself, with the screen possibly locked: if
        // what it moved to is a stream, it is on the clock from now.
        if slot.isStream, wantsToPlay {
            armStreamWatchdog(reason: .starting)
        } else {
            disarmStreamWatchdog()
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
        let status = player.timeControlStatus
        // Only a stream can be waiting on the network; a local file either plays or
        // it does not.
        isBuffering = isStreaming && status == .waitingToPlayAtSpecifiedRate
        if status == .playing {
            // Audio is coming out: the deadline has been met.
            disarmStreamWatchdog()
        } else if isStreaming, wantsToPlay, status == .waitingToPlayAtSpecifiedRate {
            armStreamWatchdog(reason: .starting)
        }
        let playing = status != .paused
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

    /// The item could not be played. What that means depends on where it was coming
    /// from, so the two are told apart here and nowhere else.
    ///
    /// A **file** that fails is a file that is missing or damaged: the track is
    /// marked as needing downloading again, because that is a lasting fact about
    /// this phone.
    ///
    /// A **stream** that fails says nothing about the track. The server may have
    /// gone, the network may have dropped, or the track may have been deleted on the
    /// server since the queue was built — a mid-stream 404. None of those is a
    /// reason to mark a local download failed, and there is no local download to
    /// mark. It is reported, the server is asked again, and playback moves on.
    private func itemFailed(_ item: AVPlayerItem, error: Error?) {
        guard let slot = itemQueueIndices[ObjectIdentifier(item)], queue.indices.contains(slot.index) else { return }
        let trackID = queue[slot.index]
        let track = self.track(id: trackID)
        let name = track?.title ?? trackID
        let url = (item.asset as? AVURLAsset)?.url
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

        guard !slot.isStream else {
            details.append("The audio was being streamed from the server, not played from a file on this iPhone, so nothing was marked as needing a new download.")
            reachability.streamingFailed()
            streamFailed(at: slot.index, error: APIError(
                kind: .transport,
                title: "Streaming failed for “\(name)”",
                url: url?.absoluteString,
                details: details,
                message: "Lo streaming di “\(name)” non è riuscito: il server non ha mandato il file, o ha smesso a metà. Se il brano non è più sul server, sincronizza la libreria; per ascoltarlo senza rete scaricalo sul telefono."
            ))
            return
        }

        let resume = wantsToPlay
        let title = "Could not play “\(name)”"
        let path = url?.path(percentEncoded: false)
        if let track, track.downloadState == .downloaded {
            details.append("The audio file is missing or unreadable, so the track was marked failed (file missing). Download it again from the Library tab.")
            recordUnplayable(track, error: APIError(
                kind: .storage, title: title, url: path, details: details,
                message: "Impossibile riprodurre “\(name)”: il file audio manca o è danneggiato, quindi il brano è segnato come da riscaricare. Scaricalo di nuovo."
            ))
        } else {
            details.append("The track is no longer downloaded on this iPhone; it was removed or re-synced during playback.")
            lastError = APIError(
                kind: .storage, title: title, url: path, details: details,
                message: "Impossibile riprodurre “\(name)”: il brano è stato rimosso dal telefono o risincronizzato durante la riproduzione. Scaricalo di nuovo."
            )
        }

        guard let next = nextPlayableIndex(after: slot.index) else {
            stopCleanly(message: nothingLeftMessage)
            return
        }
        load(index: next, position: 0, autoplay: resume)
    }

    /// A stream at `index` gave up. Show why, then carry on from the next position
    /// that can still play — which, with the server gone, is the next track on the
    /// phone. Nothing is written to the track: a stream failing is about the network,
    /// not about this phone's copy.
    private func streamFailed(at index: Int, error: APIError) {
        disarmStreamWatchdog()
        let resume = wantsToPlay
        lastError = error
        guard let next = nextPlayableIndex(after: index) else {
            stopCleanly(message: nothingLeftMessage)
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

    /// The nearest earlier position that can produce audio right now, so the back
    /// button walks past a streamed track the server can no longer serve instead of
    /// landing on it and failing.
    private func previousPlayableIndex(before index: Int?) -> Int? {
        var candidate = previousIndex(before: index)
        var tried = 0
        while let target = candidate, tried < queue.count {
            tried += 1
            if let track = track(id: queue[target]), canPlayNow(track) {
                return target
            }
            candidate = previousIndex(before: target)
        }
        return nil
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
