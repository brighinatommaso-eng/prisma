import Foundation
import SwiftData
import SwiftUI
import UIKit

/// An album's cover as plain values: the palette behind the placeholder, the name
/// of the saved image file, and when it was saved.
///
/// Read once by whoever still holds the album — a screen whose `@Query` has just
/// handed it over, or a row that has just been given the track — and passed down
/// from there.
///
/// The cover views keep `@State` and run a `.task`, so they render again on their
/// own, at a moment no parent chose and nothing else invalidated. Build 25 crashed
/// exactly there: `LocalCoverImage.body` read `album.palette` through a track whose
/// album the sync had removed, while writing the image it had just loaded. A view
/// holding nothing but values cannot be invalidated by a deletion, so it is given
/// values.
struct AlbumCover: Equatable {
    let palette: [String]?
    let fileName: String?
    let savedAt: Date?

    /// No album, or an album with no cover: the neutral tile.
    static let none = AlbumCover(palette: nil, fileName: nil, savedAt: nil)

    init(palette: [String]?, fileName: String?, savedAt: Date?) {
        self.palette = palette
        self.fileName = fileName
        self.savedAt = savedAt
    }

    /// From an album the caller has just taken out of a query.
    init(_ album: StoredAlbum) {
        self.init(palette: album.palette, fileName: album.coverFileName, savedAt: album.coverSavedAt)
    }

    /// From the album a track belongs to. The relationship is read here, in the body
    /// of whoever was handed the track, and never inside the view that draws it.
    init(of track: StoredTrack) {
        if let album = track.album {
            self.init(album)
        } else {
            self.init(palette: nil, fileName: nil, savedAt: nil)
        }
    }

    /// Changes whenever a new cover file is saved, so the image reloads.
    var loadKey: String {
        "\(fileName ?? "-")|\(savedAt?.timeIntervalSince1970 ?? 0)"
    }

    /// The covers of the first four distinct albums in `entries`, for a mosaic.
    /// Albums are told apart by identity, so choosing which four reads nothing
    /// beyond the values kept here.
    static func distinct(in entries: [PlaylistEntry]) -> [AlbumCover] {
        var seen = Set<ObjectIdentifier>()
        var result: [AlbumCover] = []
        for entry in entries {
            guard let album = entry.track?.album, seen.insert(ObjectIdentifier(album)).inserted else { continue }
            result.append(AlbumCover(album))
            if result.count == 4 { break }
        }
        return result
    }
}

/// An album cover read from Application Support/Artwork. Never touches the network.
/// Without a file it draws a neutral tile with a note glyph; an unreadable file is
/// reported through `problem`.
struct LocalCoverImage: View {
    let cover: AlbumCover
    let side: CGFloat
    @Binding var problem: String?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            CoverPlaceholder(palette: cover.palette, side: side)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: cover.loadKey) {
            load()
        }
        .accessibilityHidden(true)
    }

    private func load() {
        image = nil
        problem = nil
        guard let fileName = cover.fileName else { return }
        do {
            let url = try LocalFiles.url(.artwork, fileName)
            guard let loaded = UIImage(contentsOfFile: url.path(percentEncoded: false)) else {
                problem = "Il file della copertina di questo album manca o è illeggibile: viene riscaricato alla prossima sincronizzazione."
                return
            }
            image = loaded
        } catch {
            problem = "La copertina di questo album non si è potuta leggere. " + PlainLanguage.message(for: .from(error))
        }
    }
}

/// A cover-sized tile: the album's palette as a gradient when it has one, a
/// neutral fill otherwise, with a note glyph.
struct CoverPlaceholder: View {
    let palette: [String]?
    let side: CGFloat

    var body: some View {
        let colors = (palette ?? []).compactMap { RGBColor(hex: $0) }
            .map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        ZStack {
            if colors.count >= 2 {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Rectangle().fill(Color.gray.opacity(0.35))
            }
            Image(systemName: "music.note")
                .font(.system(size: max(10, side * 0.3), weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
        }
        .frame(width: side, height: side)
    }
}

/// A local cover, or the placeholder for a track without an album, with rounded
/// corners. `AlbumCover.none` draws the placeholder, which is what a cover with no
/// file and no palette comes to anyway.
struct CoverArt: View {
    let cover: AlbumCover
    let side: CGFloat
    let cornerRadius: CGFloat

    /// Read by nothing: this cover is decoration beside a row that reports its own
    /// problems. `LocalCoverImage` needs somewhere to put it.
    @State private var problem: String?

    var body: some View {
        LocalCoverImage(cover: cover, side: side, problem: $problem)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// The 2×2 cover of a playlist, from the first four distinct albums in playlist
/// order. With fewer albums the covers repeat across the grid.
struct PlaylistMosaic: View {
    /// Four covers at most, as values: see `AlbumCover.distinct(in:)`, which the
    /// caller runs while it still has the entries.
    let covers: [AlbumCover]
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let cell = side / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tile(0, cell)
                tile(1, cell)
            }
            HStack(spacing: 0) {
                tile(2, cell)
                tile(3, cell)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(_ index: Int, _ cell: CGFloat) -> some View {
        if covers.isEmpty {
            CoverPlaceholder(palette: nil, side: cell)
        } else {
            // Two albums sit on the diagonal; three repeat the first in the corner.
            let order: [Int] = covers.count == 2 ? [0, 1, 1, 0] : [0, 1, 2, 0]
            let pick = covers.count >= 4 ? index : order[index] % covers.count
            CoverArt(cover: covers[pick], side: cell, cornerRadius: 0)
        }
    }
}
