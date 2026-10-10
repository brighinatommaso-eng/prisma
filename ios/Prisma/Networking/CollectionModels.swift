import CryptoKit
import Foundation

// Mirrors GET/PUT /collection in backend/app/main.py. Timestamps are Unix seconds.
// Optionals match the backend's `| None` fields; a nil is left out of the request.

nonisolated struct CollectionFavourite: Codable, Sendable, Equatable {
    var videoID: String
    var title: String?
    var artist: String?
    var album: String?
    var artworkURL: String?
    var addedAt: Double

    nonisolated enum CodingKeys: String, CodingKey {
        case videoID = "video_id"
        case title
        case artist
        case album
        case artworkURL = "artwork_url"
        case addedAt = "added_at"
    }
}

nonisolated struct CollectionPlaylist: Codable, Sendable, Equatable {
    /// `Playlist.id.uuidString`.
    var id: String
    var name: String
    var createdAt: Double
    var updatedAt: Double
    /// Video ids in play order. May name a track this phone does not have, and may repeat.
    var entries: [String]

    nonisolated enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case entries
    }
}

/// The favourites and playlists, without a version: what the phone compares and merges.
nonisolated struct CollectionContent: Codable, Sendable, Equatable {
    var favourites: [CollectionFavourite]
    var playlists: [CollectionPlaylist]

    static let empty = CollectionContent(favourites: [], playlists: [])

    var isEmpty: Bool {
        favourites.isEmpty && playlists.isEmpty
    }
}

/// The body of GET /collection and PUT /collection, and of the 409 answer.
///
/// On a PUT, `version` is the version the sender's copy was based on. In every
/// answer it is the server's version after the request.
nonisolated struct ServerCollection: Codable, Sendable, Equatable {
    var version: Int
    var favourites: [CollectionFavourite]
    var playlists: [CollectionPlaylist]

    init(version: Int, content: CollectionContent) {
        self.version = version
        self.favourites = content.favourites
        self.playlists = content.playlists
    }

    var content: CollectionContent {
        CollectionContent(favourites: favourites, playlists: playlists)
    }
}

/// How the server answered a PUT.
nonisolated enum CollectionPush: Sendable {
    /// 200: stored, under the version inside.
    case accepted(ServerCollection)
    /// 409: the sent version was older than the stored one. Nothing was written; this
    /// is what the server holds.
    case stale(ServerCollection)
}

/// Comparing, merging and fingerprinting collections. Pure values, no store.
nonisolated enum CollectionMerge {
    /// Favourites newest first, then by id, so two equal collections are equal in
    /// every order-sensitive comparison and in the digest. Playlists keep the user's
    /// order, which is part of the collection.
    static func normalized(_ content: CollectionContent) -> CollectionContent {
        var copy = content
        copy.favourites.sort { left, right in
            left.addedAt != right.addedAt ? left.addedAt > right.addedAt : left.videoID < right.videoID
        }
        return copy
    }

    /// A stable fingerprint of what the collection says.
    static func digest(_ content: CollectionContent) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(normalized(content))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A playlist id compared the same way however it was cased.
    static func key(_ id: String) -> String {
        UUID(uuidString: id)?.uuidString ?? id
    }

    /// The first sync with data on both sides. Nothing is dropped from either.
    ///
    /// Favourites are a union by video id and playlists a union by id. Where both
    /// sides have the same one, the server's version stands; for a favourite, any
    /// field the server left empty is filled from the phone's copy, so no
    /// information is lost. The server's playlists come first in its order, then the
    /// phone's own.
    static func merged(local: CollectionContent, server: CollectionContent) -> CollectionContent {
        let mineByID = Dictionary(local.favourites.map { ($0.videoID, $0) }, uniquingKeysWith: { first, _ in first })
        var favourites: [CollectionFavourite] = []
        var seenFavourites = Set<String>()
        for var theirs in server.favourites {
            guard seenFavourites.insert(theirs.videoID).inserted else { continue }
            if let mine = mineByID[theirs.videoID] {
                theirs.title = theirs.title ?? mine.title
                theirs.artist = theirs.artist ?? mine.artist
                theirs.album = theirs.album ?? mine.album
                theirs.artworkURL = theirs.artworkURL ?? mine.artworkURL
            }
            favourites.append(theirs)
        }
        for mine in local.favourites where seenFavourites.insert(mine.videoID).inserted {
            favourites.append(mine)
        }

        var playlists: [CollectionPlaylist] = []
        var seenPlaylists = Set<String>()
        for theirs in server.playlists where seenPlaylists.insert(key(theirs.id)).inserted {
            playlists.append(theirs)
        }
        for mine in local.playlists where seenPlaylists.insert(key(mine.id)).inserted {
            playlists.append(mine)
        }
        return normalized(CollectionContent(favourites: favourites, playlists: playlists))
    }
}
