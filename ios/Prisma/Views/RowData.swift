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

/// An album header: cover, title, artist and year, and whether its cover failed.
struct AlbumHeading: Identifiable, Equatable {
    /// The album's server id, which is also its problem key.
    let id: Int
    let title: String
    let artist: String
    let year: Int?
    let cover: AlbumCover
    /// The last cover download failed; the next sync tries again.
    let coverFailed: Bool
}

/// Everything a track row, its state icon, its problems, its menu and its swipes
/// show. `id` is the track's server id, which every action carries.
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
    /// Identifies the running transfer, so the progress ring can find its progress.
    let downloadToken: String?
}

/// One album and the rows under it.
struct ShelfData: Identifiable, Equatable {
    let heading: AlbumHeading
    let tracks: [TrackRowData]

    var id: Int { heading.id }
    var trackIDs: [String] { tracks.map(\.id) }
}

/// The Library tab's albums filter.
struct LibraryData: Equatable {
    let shelves: [ShelfData]
    /// Tracks with no album, or whose album is no longer in the library.
    let unlisted: [TrackRowData]
    /// From the sync record, for the line at the bottom of the list.
    let lastSyncAt: Date?

    /// Every track in the order shown: albums, then tracks without an album.
    var listed: [TrackRowData] { shelves.flatMap(\.tracks) + unlisted }
    var isEmpty: Bool { shelves.isEmpty && unlisted.isEmpty }
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

/// What Search needs to decide, per result, whether it is in the library or being
/// acquired.
struct SearchIndex: Equatable {
    let tracks: [String: TrackRowData]
    let acquisitions: [String: AcquisitionData]
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

    static func heading(of album: StoredAlbum) -> AlbumHeading {
        AlbumHeading(
            id: album.serverID,
            title: album.title,
            artist: album.artist,
            year: album.year,
            cover: cover(of: album),
            coverFailed: album.coverError != nil
        )
    }

    static func row(of track: StoredTrack) -> TrackRowData {
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
            downloadToken: track.downloadToken
        )
    }

    static func acquisition(_ record: PendingAcquisition) -> AcquisitionData {
        AcquisitionData(
            id: record.videoID,
            title: record.title ?? "Senza titolo",
            artworkURL: record.artworkURL,
            stage: record.stage,
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

    /// Libreria, albums filter.
    ///
    /// Tracks are placed under their album by comparing references with the queried
    /// albums, which reads nothing from either; an album the sync has deleted is not
    /// among them, so it is never read. Both lists come from queries, so neither can
    /// contain a row that has gone.
    static func library(albums: [StoredAlbum], tracks: [StoredTrack], records: [SyncRecord]) -> LibraryData {
        let sorted = albums.sorted {
            let byArtist = $0.artist.localizedStandardCompare($1.artist)
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let live = Set(sorted.map { ObjectIdentifier($0) })

        var members: [ObjectIdentifier: [TrackRowData]] = [:]
        var unlisted: [TrackRowData] = []
        for track in tracks {
            let data = row(of: track)
            if let album = track.album, live.contains(ObjectIdentifier(album)) {
                members[ObjectIdentifier(album), default: []].append(data)
            } else {
                unlisted.append(data)
            }
        }

        let shelves = sorted.map { album in
            ShelfData(heading: heading(of: album), tracks: albumOrder(members[ObjectIdentifier(album)] ?? []))
        }
        return LibraryData(shelves: shelves, unlisted: albumOrder(unlisted), lastSyncAt: records.first?.lastSyncAt)
    }

    /// Libreria, Preferiti filter: newest favourite first.
    static func favourites(_ tracks: [StoredTrack]) -> [TrackRowData] {
        tracks
            .filter { $0.favouritedAt != nil }
            .sorted { ($0.favouritedAt ?? .distantPast) > ($1.favouritedAt ?? .distantPast) }
            .map(row(of:))
    }

    /// Libreria, Playlist filter.
    static func playlistSummaries(_ playlists: [Playlist], entries: [PlaylistEntry]) -> [PlaylistSummaryData] {
        let byPlaylist = group(entries)
        return playlists.map { playlist in
            PlaylistSummaryData(
                id: playlist.id,
                name: playlist.name,
                tracks: (byPlaylist[ObjectIdentifier(playlist)] ?? []).compactMap { $0.track.map(row(of:)) }
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
            rows: ordered.map { PlaylistRowData(entryID: $0.id, track: $0.track.map(row(of:))) }
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
        return AddToPlaylistData(track: track.map(row(of:)), albumLine: albumLine, targets: targets)
    }

    /// The Downloads tab: device downloads first by state, then by when they were
    /// asked for, with the acquisitions that have not reached the library yet.
    static func downloads(tracks: [StoredTrack], acquisitions: [PendingAcquisition]) -> DownloadsData {
        let ordered = tracks.sorted {
            // Downloading before queued, then by when they were asked for.
            if $0.downloadState != $1.downloadState {
                return $0.downloadState == .downloading
            }
            return ($0.queuedAt ?? .distantPast) < ($1.queuedAt ?? .distantPast)
        }
        return DownloadsData(tracks: ordered.map(row(of:)), acquisitions: acquisitions.map(acquisition))
    }

    /// Cerca: what a result needs to know about the library and about what is
    /// already being acquired, by video id.
    static func search(tracks: [StoredTrack], acquisitions: [PendingAcquisition]) -> SearchIndex {
        SearchIndex(
            tracks: Dictionary(tracks.map { ($0.serverID, row(of: $0)) }, uniquingKeysWith: { first, _ in first }),
            acquisitions: Dictionary(acquisitions.map { ($0.videoID, acquisition($0)) }, uniquingKeysWith: { first, _ in first })
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
