import Foundation
import SwiftData

/// Reads a stored row back from its id, at the moment it is used.
///
/// A `@Model` object may be held only for as long as the view body or the function
/// call that fetched it. The sync deletes rows whenever the server drops a track, and
/// once the context has saved, a deleted object answers nothing at all: reading any
/// property traps inside SwiftData.
///
/// `isDeleted` is not a way to find out. It reports a deletion made in this context
/// and not yet saved, which is true for a few lines inside `LibrarySync.apply` and
/// nowhere else; after the save it reads back false on an object that can no longer
/// be read, so as a safety net it protects nothing. The only honest question is "is
/// this row still in the store", and the only honest way to ask it is to look, which
/// is what this does. A row that has gone resolves to nil.
///
/// So anything outliving the body that listed it — a stored closure, a value in
/// `@State`, a context menu, a confirmation dialog, work that spans an `await` —
/// keeps ids and comes back here.
///
/// The same reasoning applies to a to-many relationship: `album.tracks` and
/// `playlist.entries` are caches on the owning object, and after a cascade delete
/// they can still hand back a row the store no longer has. Views take their rows
/// from a `@Query`, which SwiftData keeps consistent, and everything else takes them
/// from here.
///
/// `DownloadManager` and `PlaybackEngine` keep their own `track(id:)`, because they
/// must tell the user when the store itself could not be read; this returns nothing
/// rather than explaining, which is what a view wants.
enum ModelLookup {
    /// The track with this id, or nil if it is no longer in the library.
    static func track(_ id: String, in context: ModelContext) -> StoredTrack? {
        tracks([id], in: context).first
    }

    /// The tracks with these ids, in the order of `ids`, without the ones that have
    /// gone. Ids that appear twice resolve twice, so a playlist holding the same
    /// track more than once keeps its shape.
    static func tracks(_ ids: [String], in context: ModelContext) -> [StoredTrack] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        let found: [StoredTrack]
        do {
            found = try context.fetch(FetchDescriptor<StoredTrack>()).filter { wanted.contains($0.serverID) }
        } catch {
            // An unreadable store is reported by the screens that own a sync or a
            // download; a menu simply has nothing to offer.
            return []
        }
        let byID = Dictionary(found.map { ($0.serverID, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// The playlist entry with this id, or nil if the track it pointed at left the
    /// library and took it with it.
    static func playlistEntry(_ id: UUID, in context: ModelContext) -> PlaylistEntry? {
        playlistEntries([id], in: context).first
    }

    /// The playlist entries with these ids, in the order of `ids`, without the ones
    /// that have gone.
    static func playlistEntries(_ ids: [UUID], in context: ModelContext) -> [PlaylistEntry] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        let found: [PlaylistEntry]
        do {
            found = try context.fetch(FetchDescriptor<PlaylistEntry>()).filter { wanted.contains($0.id) }
        } catch {
            return []
        }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// The playlist with this id, or nil if it has been deleted.
    static func playlist(_ id: UUID, in context: ModelContext) -> Playlist? {
        playlists([id], in: context).first
    }

    /// The playlists with these ids, in the order of `ids`, without the ones that
    /// have gone.
    static func playlists(_ ids: [UUID], in context: ModelContext) -> [Playlist] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        let found: [Playlist]
        do {
            found = try context.fetch(FetchDescriptor<Playlist>()).filter { wanted.contains($0.id) }
        } catch {
            return []
        }
        let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    /// Every track currently belonging to `album`, read from the store rather than
    /// from `album.tracks`.
    ///
    /// Membership is compared by object identity, never by reading a property of the
    /// album each track points at: that album may be one the sync has just deleted,
    /// and comparing two references reads nothing.
    static func members(of album: StoredAlbum, in context: ModelContext) -> [StoredTrack] {
        let wanted = ObjectIdentifier(album)
        do {
            return try context.fetch(FetchDescriptor<StoredTrack>()).filter { track in
                track.album.map { ObjectIdentifier($0) == wanted } ?? false
            }
        } catch {
            return []
        }
    }
}
