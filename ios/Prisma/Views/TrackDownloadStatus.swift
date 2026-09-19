import Foundation
import SwiftData
import SwiftUI
import UIKit

/// An album cover read from Application Support/Artwork. Never touches the network.
/// Without a file it draws a neutral tile with a note glyph; an unreadable file is
/// reported through `problem`.
struct LocalCoverImage: View {
    let album: StoredAlbum
    let side: CGFloat
    @Binding var problem: String?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            CoverPlaceholder(palette: album.palette, side: side)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: loadKey) {
            load()
        }
        .accessibilityHidden(true)
    }

    /// Changes whenever a new cover file is saved, so the image reloads.
    private var loadKey: String {
        "\(album.coverFileName ?? "-")|\(album.coverSavedAt?.timeIntervalSince1970 ?? 0)"
    }

    private func load() {
        image = nil
        problem = nil
        guard let fileName = album.coverFileName else { return }
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
/// corners.
struct CoverArt: View {
    let album: StoredAlbum?
    let side: CGFloat
    let cornerRadius: CGFloat

    @State private var problem: String?

    var body: some View {
        Group {
            if let album {
                LocalCoverImage(album: album, side: side, problem: $problem)
            } else {
                CoverPlaceholder(palette: nil, side: side)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// The 2×2 cover of a playlist, from the first four distinct albums in playlist
/// order. With fewer albums the covers repeat across the grid.
struct PlaylistMosaic: View {
    /// The playlist's entries as the caller's query lists them, never
    /// `playlist.entries`. See `PlaylistStore.ordered(_:of:)`.
    let entries: [PlaylistEntry]
    let side: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let albums = Self.distinctAlbums(in: entries)
        let cell = side / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tile(albums, 0, cell)
                tile(albums, 1, cell)
            }
            HStack(spacing: 0) {
                tile(albums, 2, cell)
                tile(albums, 3, cell)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func tile(_ albums: [StoredAlbum], _ index: Int, _ cell: CGFloat) -> some View {
        if albums.isEmpty {
            CoverPlaceholder(palette: nil, side: cell)
        } else {
            // Two albums sit on the diagonal; three repeat the first in the corner.
            let order: [Int] = albums.count == 2 ? [0, 1, 1, 0] : [0, 1, 2, 0]
            let pick = albums.count >= 4 ? index : order[index] % albums.count
            CoverArt(album: albums[pick], side: cell, cornerRadius: 0)
        }
    }

    /// Albums are told apart by identity rather than by `serverID`, so choosing
    /// which four to draw reads nothing from them.
    static func distinctAlbums(in entries: [PlaylistEntry]) -> [StoredAlbum] {
        var seen = Set<ObjectIdentifier>()
        var result: [StoredAlbum] = []
        for entry in entries {
            guard let album = entry.track?.album, seen.insert(ObjectIdentifier(album)).inserted else { continue }
            result.append(album)
            if result.count == 4 { break }
        }
        return result
    }
}
