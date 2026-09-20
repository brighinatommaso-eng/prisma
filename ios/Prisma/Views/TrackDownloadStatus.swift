import Foundation
import SwiftData
import SwiftUI
import UIKit

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
