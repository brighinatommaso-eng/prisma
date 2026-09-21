import Foundation
import SwiftData

// MARK: - What a screen shows

/// The values every screen is built from.
///
/// Nothing below a screen's body is a model object. A `@Model` may be read only in
/// the projection pass at the top of that body — `Projection`, below — and what
/// comes out is plain values: strings, numbers, enums, file names, ids.
///
/// The reason is `ForEach`. SwiftUI keeps each child's element and re-runs that one
/// child's closure later, by itself, on the element it captured; if the element is a
/// model object the sync has since deleted, the closure traps on the first property
/// it reads. Four builds crashed that way, each in a different view, and the last one
/// inside an initialiser taking a `StoredAlbum` — a value type whose initialiser was
/// still a read. So `ForEach` iterates values, initialisers take values, and the
/// reading happens once, in one place, before any of it.
///
/// Acting on a row is separate: menus, buttons, sheets and confirmations carry ids
/// and read the row back through `ModelLookup` at the moment of the tap.

/// An album's cover: the palette behind the placeholder, the name of the saved image
/// file, and when it was saved.
struct AlbumCover: Equatable {
    let palette: [String]?
    let fileName: String?
    let savedAt: Date?

    /// No album, or an album with no cover: the neutral tile.
    static let none = AlbumCover(palette: nil, fileName: nil, savedAt: nil)

    /// Changes whenever a new cover file is saved, so the image reloads.
    var loadKey: String {
        "\(fileName ?? "-")|\(savedAt?.timeIntervalSince1970 ?? 0)"
    }
}

/// What the app has of a track, and therefore what its row may offer.
///
/// A row is not only a library track any more: Preferiti lists favourites, and a
/// favourite may exist with no track on the server and none on the phone. Rather
/// than a second row component with a second menu, the one row carries this and
/// reads its actions off it.
enum TrackPresence: String, Equatable, Sendable {
    /// A library row exists and the server still lists the track.
    case inLibrary
    /// A library row exists, and a sync confirmed the server let go of its copy
    /// because this phone asked for the only one. Whatever is here is all there is.
    case phoneOnly
    /// No library row at all: a favourite added from Cerca with the plus, whose
    /// track is on neither the server nor the phone.
    case favouriteOnly
}

/// What the app knows about the server right now, as a value.
///
/// `ServerReachability` holds the truth; this is the shape the interface reasons
/// in. It is not part of the store projection and does not need to be: reachability
/// is a service in the environment, like `DownloadManager` and `PlaybackEngine`,
/// and reading it below a body is safe because there is no row that can be deleted
/// underneath it. What it must not do is disagree with the engine, so the
/// playability rule is written once, as `TrackRowData.canPlay`, and the engine's
/// `canPlayNow` is the same rule over the stored track.
enum ServerState: Equatable, Sendable {
    /// Nothing has asked the server yet in this session.
    case unknown
    case reachable
    case unreachable

    init(_ isReachable: Bool?) {
        switch isReachable {
        case nil: self = .unknown
        case true?: self = .reachable
        case false?: self = .unreachable
        }
    }

    /// Streaming is worth attempting. "Not asked yet" counts as yes: attempting is
    /// the fastest way to find out, and the attempt is bounded by the engine's
    /// streaming deadline, so it cannot hang.
    var mayStream: Bool { self != .unreachable }
}

/// The three states a Preferiti row tells apart, and the words for each.
///
/// A track on the server is now playable too, by streaming, but only while the
/// server answers — so what the row says about it depends on `ServerState`, and the
/// three states no longer map one-to-one onto "plays" and "does not play".
enum FavouriteState: Equatable, Sendable {
    /// The file is on this phone: it plays, with or without a network.
    case onPhone
    /// The server has it and this phone does not: it streams while the server
    /// answers, and nothing can play it when it does not.
    case onServer
    /// Neither the server nor this phone has it.
    case notAcquired

    /// The row's subtitle prefix, so the state is legible without tapping.
    func label(_ server: ServerState) -> String {
        switch self {
        case .onPhone:
            return "Sul telefono"
        case .onServer:
            switch server {
            case .reachable: return "Sul server · in streaming"
            case .unreachable: return "Sul server · non raggiungibile"
            case .unknown: return "Sul server"
            }
        case .notAcquired:
            return "Non ancora scaricato"
        }
    }

    /// Whether this state can produce audio with the server in this state.
    func canPlay(_ server: ServerState) -> Bool {
        switch self {
        case .onPhone: return true
        case .onServer: return server.mayStream
        case .notAcquired: return false
        }
    }

    /// Why the track will not play, in full, or nil when it will.
    func reason(title: String, server: ServerState) -> String? {
        switch self {
        case .onPhone:
            return nil
        case .onServer:
            guard !server.mayStream else { return nil }
            return "“\(title)” è sul server ma non su questo telefono, e il server ora non risponde, quindi non si può nemmeno riprodurre in streaming. Scaricalo sul telefono quando il server torna raggiungibile, così lo ascolti anche in modalità aereo."
        case .notAcquired:
            return "“\(title)” non è ancora stato scaricato: non è né sul server né su questo telefono. Scegli dove scaricarlo per poterlo ascoltare."
        }
    }
}

/// Everything a track row, its state icon, its problems, its menu and its swipes
/// show. `id` is the track's server id — which is the YouTube video id, and so also
/// the id of its favourite — and every action carries it.
struct TrackRowData: Identifiable, Equatable {
    let id: String
    /// Already resolved, so no view has to decide what an untitled track is called.
    let title: String
    let artist: String?
    /// The album's title, for "In riproduzione da" in the player.
    let albumTitle: String?
    /// For grouping covers without reading an album again.
    let albumID: Int?
    let durationS: Int?
    let downloadState: DownloadState
    let failureCause: FailureCause?
    let isFavourite: Bool
    let cover: AlbumCover
    /// Absolute, from search. Only a favourite with no track has one: a library
    /// track shows its album's cover from disk instead.
    let artworkURL: String?
    let presence: TrackPresence
    /// The chain running for this track right now, when one is. Only Preferiti
    /// fills it in; every other screen has its own place for acquisitions.
    let acquisition: AcquisitionData?
    /// Identifies the running transfer, so the progress ring can find its progress.
    let downloadToken: String?

    /// Which of the three Preferiti states this row is in.
    ///
    /// The file decides first: a track on the phone plays, whatever the server has
    /// since done. Otherwise a library row the server still lists is "sul server",
    /// and everything else — a claimed copy the server has dropped and the phone no
    /// longer holds, or a favourite with no track at all — is "non acquisito".
    var favouriteState: FavouriteState {
        if downloadState == .downloaded { return .onPhone }
        switch presence {
        case .inLibrary: return .onServer
        case .phoneOnly, .favouriteOnly: return .notAcquired
        }
    }

    /// The file is here. Plays with no network at all, and is the source chosen
    /// even when the server is one hop away.
    var isOnPhone: Bool { downloadState == .downloaded }

    /// The server has a file for this track and this phone has not, so it is the
    /// one kind of row that streaming is for. A copy this phone claimed as its only
    /// one, and a favourite with no track anywhere, are not: `/tracks/{id}/file`
    /// would answer 404 for both.
    var isOnServerOnly: Bool { presence == .inLibrary && downloadState != .downloaded }

    /// Can it produce audio right now? The rule the engine implements, as a value,
    /// so a row and the engine cannot disagree about what a tap will do.
    func canPlay(_ server: ServerState) -> Bool {
        isOnPhone || (isOnServerOnly && server.mayStream)
    }

    /// Playlists, Elimina dal server and the device download all need a library row.
    var hasLibraryRow: Bool { presence != .favouriteOnly }

    /// A transfer or a chain is under way, so the row offers no new one.
    var isBusy: Bool {
        downloadState == .queued || downloadState == .downloading || (acquisition?.isActive ?? false)
    }

    var favouriteDraft: FavouriteDraft {
        FavouriteDraft(
            videoID: id,
            title: title,
            artist: artist,
            albumName: albumTitle,
            artworkURL: artworkURL,
            durationS: durationS
        )
    }

    var acquisitionRequest: AcquisitionRequest {
        AcquisitionRequest(
            videoID: id,
            title: title,
            artist: artist,
            albumName: albumTitle,
            durationS: durationS,
            artworkURL: artworkURL
        )
    }
}

/// Why a playlist slot has nothing to show.
enum MissingEntryReason: Equatable, Sendable {
    /// The slot pointed at a library row that has gone, and only the slot is left.
    case leftTheLibrary
    /// The slot names a video id that is in neither the library nor Preferiti:
    /// a track added from Cerca whose favourite was removed afterwards.
    case unknownTrack

    var text: String {
        switch self {
        case .leftTheLibrary:
            return "Brano non più in libreria"
        case .unknownTrack:
            return "Brano tolto dai preferiti e mai scaricato"
        }
    }
}

/// One slot of a playlist. `track` is nil only when nothing at all is known about
/// what the slot names, and `missing` then says which of the two ways that happened.
struct PlaylistRowData: Identifiable, Equatable {
    let entryID: UUID
    let track: TrackRowData?
    let missing: MissingEntryReason?

    var id: UUID { entryID }
}

/// A playlist as its own screen shows it.
struct PlaylistData: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rows: [PlaylistRowData]
    /// Some slot still names its track by video id alone although the library now
    /// has a row for it: the sync wrote the track after the slot was added. The
    /// screen hands the playlist to `PlaylistStore.adoptLibraryRows(in:)` when this
    /// turns true, so the slot becomes an ordinary one without waiting for a tap.
    let awaitsAdoption: Bool

    var tracks: [TrackRowData] { rows.compactMap(\.track) }
    var trackIDs: [String] { tracks.map(\.id) }
    var covers: [AlbumCover] { Projection.covers(of: tracks) }
    /// Offsets into `rows` whose track can produce audio with the server in this
    /// state: on the phone, or on the server while it answers.
    func playable(_ server: ServerState) -> [Int] {
        rows.indices.filter { rows[$0].track?.canPlay(server) ?? false }
    }

    /// Distinct tracks the server has and this phone has not: the ones "Scarica i
    /// brani mancanti" can actually start, because a device download fetches
    /// GET /tracks/{id}/file and so needs a track the server still holds.
    var downloadableCount: Int {
        distinct { $0.isOnServerOnly }
    }

    /// Distinct tracks that are in no library at all — added with the plus, or
    /// claimed as this phone's only copy and then removed. A device download cannot
    /// fetch them: they have to be asked of the server with a destination, which is
    /// what tapping one of their rows does.
    var notAcquiredCount: Int {
        distinct { !$0.isOnPhone && !$0.isOnServerOnly }
    }

    private func distinct(_ isIncluded: (TrackRowData) -> Bool) -> Int {
        Set(rows.compactMap { row -> String? in
            guard let track = row.track, isIncluded(track) else { return nil }
            return track.id
        }).count
    }
}

/// A playlist in the Library tab's playlists list.
struct PlaylistSummaryData: Identifiable, Equatable {
    let id: UUID
    let name: String
    let tracks: [TrackRowData]

    var covers: [AlbumCover] { Projection.covers(of: tracks) }
}

/// One playlist as an Aggiungi a playlist… destination.
struct PlaylistTargetData: Identifiable, Equatable {
    let id: UUID
    let name: String
    let entryCount: Int
    /// The track being added is already in it, so it would be added a second time.
    let holdsTrack: Bool
}

/// The Aggiungi a playlist… sheet.
struct AddToPlaylistData: Equatable {
    /// nil once the track has left the library while the sheet was open.
    let track: TrackRowData?
    let albumLine: String?
    let targets: [PlaylistTargetData]
}

/// One line of the Dai preferiti picker: a favourite, and whether the playlist
/// already holds it.
struct FavouritePickerRow: Identifiable, Equatable {
    let track: TrackRowData
    /// Shown as such and not selectable: a picker exists to say what is already
    /// there, so it never offers to put the same track in twice.
    let isInPlaylist: Bool

    var id: String { track.id }
}

/// Everything the Dai preferiti sheet needs, from one read of the store: which
/// playlist it is adding to, and the collection to pick from, each line marked with
/// whether the playlist already holds it.
struct PlaylistAdditionData: Equatable {
    /// nil once the playlist has been deleted while the sheet was open.
    let playlistName: String?
    let rows: [FavouritePickerRow]

    var addableCount: Int { rows.filter { !$0.isInPlaylist }.count }
}

/// A track being acquired from Search, before it is a library track.
struct AcquisitionData: Identifiable, Equatable {
    /// The YouTube video id, which every action carries.
    let id: String
    let title: String
    let artworkURL: String?
    let stage: AcquisitionStage
    let destination: AcquisitionDestination
    let serverJobState: String?
    let serverProgress: Double?
    let failureMessage: String?
    /// Which part of the chain the failure belongs to, for the row subtitle.
    let failurePhase: String?

    var isActive: Bool { stage != .failed }
}

/// The Downloads tab.
struct DownloadsData: Equatable {
    let tracks: [TrackRowData]
    let acquisitions: [AcquisitionData]

    func tracks(in states: Set<DownloadState>) -> [TrackRowData] {
        tracks.filter { states.contains($0.downloadState) }
    }

    var isEmpty: Bool { tracks.isEmpty && acquisitions.isEmpty }
}

/// What Search needs to decide, per result, whether it is in the library, already a
/// favourite, or being acquired. Keyed by video id, which every one of the three
/// shares.
struct SearchIndex: Equatable {
    let tracks: [String: TrackRowData]
    let acquisitions: [String: AcquisitionData]
    let favourites: Set<String>
    /// The playlist results are being added to, when Cerca is open over one; nil in
    /// the Cerca tab, and nil once that playlist has been deleted.
    let playlist: PlaylistSearchTarget?
}

/// The playlist Cerca adds to when it is presented over a playlist: its name, and
/// the video ids it already holds, so a result can say it is already there without
/// a library track existing.
struct PlaylistSearchTarget: Equatable {
    let id: UUID
    let name: String
    let alreadyIn: Set<String>

    func slot(for videoID: String) -> PlaylistSlotTarget {
        PlaylistSlotTarget(playlistID: id, playlistName: name, holdsTrack: alreadyIn.contains(videoID))
    }
}

/// One search result's view of that playlist: where it would go, and whether it is
/// there already. An id and strings only, so a row can carry it and act on it later.
struct PlaylistSlotTarget: Equatable {
    let playlistID: UUID
    let playlistName: String
    let holdsTrack: Bool
}

/// Where a queued line's audio would come from, so the queue can show what will be
/// skipped instead of silently skipping it.
enum QueueRowSource: Equatable, Sendable {
    /// The file is on this phone.
    case onPhone
    /// Only the server has it: it streams while the server answers.
    case onServer
    /// In the library, but on neither the phone nor the server.
    case nowhere
    /// Not in the library any more: it was queued and then deleted.
    case gone
}

/// One line of the play queue.
struct QueueRowData: Identifiable, Equatable {
    /// The position in the queue: a playlist may hold the same track twice.
    let id: Int
    let title: String
    let artist: String
    let source: QueueRowSource

    func canPlay(_ server: ServerState) -> Bool {
        switch source {
        case .onPhone: return true
        case .onServer: return server.mayStream
        case .nowhere, .gone: return false
        }
    }

    /// Why this line will be passed over, or nil when it will play.
    func skippedReason(_ server: ServerState) -> String? {
        switch source {
        case .onPhone:
            return nil
        case .onServer:
            return server.mayStream ? nil : "Solo sul server, non raggiungibile"
        case .nowhere:
            return "Non è sul telefono né sul server"
        case .gone:
            return "Non più in libreria"
        }
    }
}

// MARK: - Reading the store, once

/// The only code in the interface that reads a `@Model`.
///
/// Every function here is free, takes model objects and returns values. A screen
/// calls exactly one of them, at the top of its body, out of its own `@Query`
/// results — which SwiftData keeps consistent, so nothing here is ever handed a row
/// that has gone. Nothing below that call sees a model again.
enum Projection {
    // MARK: Pieces

    static func cover(of album: StoredAlbum?) -> AlbumCover {
        guard let album else { return .none }
        return AlbumCover(palette: album.palette, fileName: album.coverFileName, savedAt: album.coverSavedAt)
    }

    static func row(of track: StoredTrack, acquisition: AcquisitionData? = nil) -> TrackRowData {
        let album = track.album
        return TrackRowData(
            id: track.serverID,
            title: track.title ?? "Senza titolo",
            artist: album?.artist,
            albumTitle: album?.title,
            albumID: album?.serverID,
            durationS: track.durationS,
            downloadState: track.downloadState,
            failureCause: track.failureCause,
            isFavourite: track.isFavourite,
            cover: cover(of: album),
            artworkURL: nil,
            presence: track.serverDroppedAt == nil ? .inLibrary : .phoneOnly,
            acquisition: acquisition,
            downloadToken: track.downloadToken
        )
    }

    /// A favourite with no track behind it: nothing has been downloaded anywhere,
    /// so everything the row shows comes from what search returned when the plus
    /// was tapped.
    static func row(of favourite: FavouriteTrack, acquisition: AcquisitionData? = nil) -> TrackRowData {
        TrackRowData(
            id: favourite.videoID,
            title: favourite.title ?? "Senza titolo",
            artist: favourite.artist,
            albumTitle: favourite.albumName,
            albumID: nil,
            durationS: favourite.durationS,
            downloadState: .notDownloaded,
            failureCause: nil,
            isFavourite: true,
            cover: .none,
            artworkURL: favourite.artworkURL,
            presence: .favouriteOnly,
            acquisition: acquisition,
            downloadToken: nil
        )
    }

    static func acquisition(_ record: PendingAcquisition) -> AcquisitionData {
        AcquisitionData(
            id: record.videoID,
            title: record.title ?? "Senza titolo",
            artworkURL: record.artworkURL,
            stage: record.stage,
            destination: record.destination,
            serverJobState: record.serverJobState,
            serverProgress: record.serverProgress,
            failureMessage: record.failureMessage,
            failurePhase: record.failure?.phase
        )
    }

    /// The first four distinct albums' covers, for a playlist mosaic. Distinctness is
    /// by album id, a value, so no album is read again.
    static func covers(of rows: [TrackRowData]) -> [AlbumCover] {
        var seen = Set<Int>()
        var result: [AlbumCover] = []
        for row in rows {
            guard let albumID = row.albumID, seen.insert(albumID).inserted else { continue }
            result.append(row.cover)
            if result.count == 4 { break }
        }
        return result
    }

    // MARK: Screens

    /// Libreria, Preferiti: the collection, newest favourite first.
    ///
    /// Driven by the favourites, not by the library: a favourite may have no track
    /// anywhere, and must still be a row. The library and the acquisitions are only
    /// looked up by video id, which reads a string from each and nothing else, so a
    /// favourite whose track the sync deleted a moment ago simply finds nothing and
    /// becomes a "non acquisito" row.
    static func favourites(
        favourites: [FavouriteTrack],
        tracks: [StoredTrack],
        acquisitions: [PendingAcquisition]
    ) -> [TrackRowData] {
        let byID = Dictionary(tracks.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = Dictionary(
            acquisitions.map { ($0.videoID, acquisition($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return favourites
            .sorted { $0.addedAt > $1.addedAt }
            .map { favourite in
                if let track = byID[favourite.videoID] {
                    return row(of: track, acquisition: pending[favourite.videoID])
                }
                return row(of: favourite, acquisition: pending[favourite.videoID])
            }
    }

    /// Libreria, Playlist filter.
    static func playlistSummaries(
        _ playlists: [Playlist],
        entries: [PlaylistEntry],
        tracks: [StoredTrack],
        favourites: [FavouriteTrack]
    ) -> [PlaylistSummaryData] {
        let byPlaylist = group(entries)
        let index = SlotIndex(tracks: tracks, favourites: favourites)
        return playlists.map { playlist in
            PlaylistSummaryData(
                id: playlist.id,
                name: playlist.name,
                tracks: (byPlaylist[ObjectIdentifier(playlist)] ?? []).compactMap { slot($0, in: index).track }
            )
        }
    }

    /// One playlist's screen. nil once the playlist itself is gone.
    static func playlist(
        id: UUID,
        playlists: [Playlist],
        entries: [PlaylistEntry],
        tracks: [StoredTrack],
        favourites: [FavouriteTrack]
    ) -> PlaylistData? {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return nil }
        let ordered = group(entries)[ObjectIdentifier(playlist)] ?? []
        let index = SlotIndex(tracks: tracks, favourites: favourites)
        return PlaylistData(
            id: playlist.id,
            name: playlist.name,
            rows: ordered.map { slot($0, in: index) },
            awaitsAdoption: ordered.contains { entry in
                entry.track == nil && entry.videoID.map { index.tracks[$0] != nil } == true
            }
        )
    }

    /// The library and Preferiti by video id, built once per projection pass so a
    /// slot is resolved by two dictionary lookups rather than a search.
    private struct SlotIndex {
        let tracks: [String: StoredTrack]
        let favourites: [String: FavouriteTrack]

        init(tracks: [StoredTrack], favourites: [FavouriteTrack]) {
            self.tracks = Dictionary(tracks.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
            self.favourites = Dictionary(favourites.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// What one slot shows.
    ///
    /// The relationship first, because it is the row the slot was made from and it
    /// carries the download state. Failing that, the video id: a slot added from
    /// Cerca has no relationship until its track is acquired, and until then it is
    /// its favourite that knows the title. Only an id nobody recognises, or a slot
    /// that names nothing at all, has nothing to show.
    private static func slot(_ entry: PlaylistEntry, in index: SlotIndex) -> PlaylistRowData {
        if let track = entry.track {
            return PlaylistRowData(entryID: entry.id, track: row(of: track), missing: nil)
        }
        guard let videoID = entry.videoID else {
            return PlaylistRowData(entryID: entry.id, track: nil, missing: .leftTheLibrary)
        }
        if let track = index.tracks[videoID] {
            return PlaylistRowData(entryID: entry.id, track: row(of: track), missing: nil)
        }
        if let favourite = index.favourites[videoID] {
            return PlaylistRowData(entryID: entry.id, track: row(of: favourite), missing: nil)
        }
        return PlaylistRowData(entryID: entry.id, track: nil, missing: .unknownTrack)
    }

    /// The Aggiungi a playlist… sheet, for the track that opened it.
    static func addToPlaylist(
        trackID: String,
        tracks: [StoredTrack],
        playlists: [Playlist],
        entries: [PlaylistEntry]
    ) -> AddToPlaylistData {
        let track = tracks.first { $0.serverID == trackID }
        let albumLine = track?.album.map { "\($0.artist) · \($0.title)" }
        let byPlaylist = group(entries)
        let targets = playlists.map { playlist in
            let listed = byPlaylist[ObjectIdentifier(playlist)] ?? []
            return PlaylistTargetData(
                id: playlist.id,
                name: playlist.name,
                entryCount: listed.count,
                holdsTrack: listed.contains { $0.track?.serverID == trackID }
            )
        }
        return AddToPlaylistData(track: track.map { row(of: $0) }, albumLine: albumLine, targets: targets)
    }

    /// The Downloads tab: device downloads first by state, then by when they were
    /// asked for, with the acquisitions that have not reached the library yet.
    ///
    /// An acquisition whose device download has started is left out: the track's own
    /// row is already showing that transfer, and listing both would be two rows for
    /// one download. A Telefono acquisition outlives its handoff — it still has the
    /// server's copy to delete — and that last step is its own row again, because
    /// nothing else says it is happening.
    static func downloads(tracks: [StoredTrack], acquisitions: [PendingAcquisition]) -> DownloadsData {
        let ordered = tracks.sorted {
            // Downloading before queued, then by when they were asked for.
            if $0.downloadState != $1.downloadState {
                return $0.downloadState == .downloading
            }
            return ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast)
        }
        let rows = ordered.map { row(of: $0) }
        let transferring: Set<DownloadState> = [.queued, .downloading, .downloaded]
        let started = Set(rows.filter { transferring.contains($0.downloadState) }.map(\.id))
        let records = acquisitions
            .map { acquisition($0) }
            .filter { $0.stage != .handingOff || !started.contains($0.id) }
        return DownloadsData(tracks: rows, acquisitions: records)
    }

    /// The one line Libreria shows about syncing.
    static func lastSync(_ records: [SyncRecord]) -> Date? {
        records.first?.lastSyncAt
    }

    /// Cerca: what a result needs to know about the library, about Preferiti and
    /// about what is already being acquired, by video id — and, when Cerca is open
    /// over a playlist, which of those video ids the playlist already holds.
    ///
    /// One pass for the tab and for the overlay, so the two cannot come to disagree
    /// about what a result is. The tab passes no `playlistID`, and then no playlist
    /// is looked at.
    static func search(
        tracks: [StoredTrack],
        favourites: [FavouriteTrack],
        acquisitions: [PendingAcquisition],
        playlistID: UUID? = nil,
        playlists: [Playlist] = [],
        entries: [PlaylistEntry] = []
    ) -> SearchIndex {
        var target: PlaylistSearchTarget?
        if let playlistID, let playlist = playlists.first(where: { $0.id == playlistID }) {
            let listed = group(entries)[ObjectIdentifier(playlist)] ?? []
            // `trackID` reads the id off the slot, or off the library row it points
            // at for a slot written before slots carried one.
            target = PlaylistSearchTarget(
                id: playlist.id,
                name: playlist.name,
                alreadyIn: Set(listed.compactMap(\.trackID))
            )
        }
        return SearchIndex(
            tracks: Dictionary(tracks.map { ($0.serverID, row(of: $0)) }, uniquingKeysWith: { first, _ in first }),
            acquisitions: Dictionary(acquisitions.map { ($0.videoID, acquisition($0)) }, uniquingKeysWith: { first, _ in first }),
            favourites: Set(favourites.map(\.videoID)),
            playlist: target
        )
    }

    /// The Dai preferiti sheet: the collection, and what is already in the playlist.
    ///
    /// A picker shows no transfers, so no acquisitions are read for it — a row here
    /// says what the track is, not what is happening to it.
    static func playlistAddition(
        playlistID: UUID,
        playlists: [Playlist],
        entries: [PlaylistEntry],
        favourites: [FavouriteTrack],
        tracks: [StoredTrack]
    ) -> PlaylistAdditionData {
        let playlist = playlists.first { $0.id == playlistID }
        let listed = playlist.map { group(entries)[ObjectIdentifier($0)] ?? [] } ?? []
        // `trackID` reads the id off the slot, or off the library row it points at
        // for a slot written before slots carried one.
        let alreadyIn = Set(listed.compactMap(\.trackID))
        // Named in full: the parameter `favourites` shadows the function of the
        // same name, and the collection here is exactly the Preferiti list.
        let rows = Projection.favourites(favourites: favourites, tracks: tracks, acquisitions: [])
            .map { FavouritePickerRow(track: $0, isInPlaylist: alreadyIn.contains($0.id)) }
        return PlaylistAdditionData(playlistName: playlist?.name, rows: rows)
    }

    /// The play queue sheet: the engine's ids against the library.
    static func queue(ids: [String], tracks: [StoredTrack]) -> [QueueRowData] {
        let byID = Dictionary(tracks.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.enumerated().map { offset, id in
            guard let track = byID[id] else {
                return QueueRowData(id: offset, title: "Brano non più in libreria", artist: "", source: .gone)
            }
            let source: QueueRowSource
            if track.downloadState == .downloaded {
                source = .onPhone
            } else {
                source = track.serverDroppedAt == nil ? .onServer : .nowhere
            }
            return QueueRowData(
                id: offset,
                title: track.title ?? "Senza titolo",
                artist: track.album?.artist ?? "",
                source: source
            )
        }
    }

    // MARK: Helpers

    /// Entries by the playlist they belong to, in the user's order. Membership is by
    /// reference, so no playlist is read to work it out, and the entries come from a
    /// query rather than from `playlist.entries`, which is a cache on the playlist
    /// and can still list one the sync has deleted.
    private static func group(_ entries: [PlaylistEntry]) -> [ObjectIdentifier: [PlaylistEntry]] {
        var byPlaylist: [ObjectIdentifier: [PlaylistEntry]] = [:]
        for entry in entries {
            guard let playlist = entry.playlist else { continue }
            byPlaylist[ObjectIdentifier(playlist), default: []].append(entry)
        }
        return byPlaylist.mapValues { $0.sorted { $0.position < $1.position } }
    }
}
