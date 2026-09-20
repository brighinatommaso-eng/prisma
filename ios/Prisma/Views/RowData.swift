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

/// The three states a Preferiti row tells apart, and the words for each.
///
/// Streaming does not exist yet, so two of the three cannot be played, and each
/// says why in its own terms rather than sharing one vague sentence.
enum FavouriteState: Equatable, Sendable {
    /// The file is on this phone: it plays.
    case onPhone
    /// The server has it and this phone does not.
    case onServer
    /// Neither the server nor this phone has it.
    case notAcquired

    /// The row's subtitle prefix, so the state is legible without tapping.
    var label: String {
        switch self {
        case .onPhone: return "Sul telefono"
        case .onServer: return "Sul server"
        case .notAcquired: return "Non ancora scaricato"
        }
    }

    /// Why the track will not play, in full, or nil when it will.
    func reason(title: String) -> String? {
        switch self {
        case .onPhone:
            return nil
        case .onServer:
            return "“\(title)” è sul server ma non su questo telefono, e Prisma non riproduce ancora in streaming: scaricalo sul telefono per ascoltarlo."
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
    /// The album's numbering, for album order.
    let trackNo: Int?
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

    var isPlayable: Bool { downloadState == .downloaded }

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

/// One slot of a playlist. `track` is nil when the track has left the library and
/// only the entry is left to remove.
struct PlaylistRowData: Identifiable, Equatable {
    let entryID: UUID
    let track: TrackRowData?

    var id: UUID { entryID }
}

/// A playlist as its own screen shows it.
struct PlaylistData: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rows: [PlaylistRowData]

    var tracks: [TrackRowData] { rows.compactMap(\.track) }
    var trackIDs: [String] { tracks.map(\.id) }
    var covers: [AlbumCover] { Projection.covers(of: tracks) }
    /// Offsets into `rows` whose track is on the phone.
    var playable: [Int] { rows.indices.filter { rows[$0].track?.downloadState == .downloaded } }
    /// Distinct tracks not on the phone.
    var missingCount: Int {
        Set(rows.compactMap { row -> String? in
            guard let track = row.track, track.downloadState != .downloaded else { return nil }
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
}

/// One line of the play queue.
struct QueueRowData: Identifiable, Equatable {
    /// The position in the queue: a playlist may hold the same track twice.
    let id: Int
    let title: String
    let artist: String
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
            trackNo: track.trackNo,
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
            trackNo: nil,
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

    /// Album order: by track number, unnumbered tracks last, then by title. The same
    /// order `StoredTrack.albumOrder` gives, on values.
    static func albumOrder(_ rows: [TrackRowData]) -> [TrackRowData] {
        rows.sorted {
            switch ($0.trackNo, $1.trackNo) {
            case let (left?, right?) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
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
    static func playlistSummaries(_ playlists: [Playlist], entries: [PlaylistEntry]) -> [PlaylistSummaryData] {
        let byPlaylist = group(entries)
        return playlists.map { playlist in
            PlaylistSummaryData(
                id: playlist.id,
                name: playlist.name,
                tracks: (byPlaylist[ObjectIdentifier(playlist)] ?? []).compactMap { entry in entry.track.map { row(of: $0) } }
            )
        }
    }

    /// One playlist's screen. nil once the playlist itself is gone.
    static func playlist(id: UUID, playlists: [Playlist], entries: [PlaylistEntry]) -> PlaylistData? {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return nil }
        let ordered = group(entries)[ObjectIdentifier(playlist)] ?? []
        return PlaylistData(
            id: playlist.id,
            name: playlist.name,
            rows: ordered.map { entry in PlaylistRowData(entryID: entry.id, track: entry.track.map { row(of: $0) }) }
        )
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

    /// Cerca: what a result needs to know about the library, about Preferiti and
    /// about what is already being acquired, by video id.
    static func search(
        tracks: [StoredTrack],
        favourites: [FavouriteTrack],
        acquisitions: [PendingAcquisition]
    ) -> SearchIndex {
        SearchIndex(
            tracks: Dictionary(tracks.map { ($0.serverID, row(of: $0)) }, uniquingKeysWith: { first, _ in first }),
            acquisitions: Dictionary(acquisitions.map { ($0.videoID, acquisition($0)) }, uniquingKeysWith: { first, _ in first }),
            favourites: Set(favourites.map(\.videoID))
        )
    }

    /// The play queue sheet: the engine's ids against the library.
    static func queue(ids: [String], tracks: [StoredTrack]) -> [QueueRowData] {
        let byID = Dictionary(tracks.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.enumerated().map { offset, id in
            let track = byID[id]
            return QueueRowData(
                id: offset,
                title: track?.title ?? "Brano non più in libreria",
                artist: track?.album?.artist ?? ""
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
