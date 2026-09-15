import Foundation
import SwiftUI
import UIKit

/// Artwork loaded through `APIClient`, so it gets the same timeouts and error text
/// as every other request. AsyncImage is not used because its failures carry no
/// URL and cannot be shown in full.
///
/// A failure is shown as a warning icon in the image box and written to `failure`,
/// so the enclosing row can print the error where there is room to read it.
struct RemoteImage: View {
    let client: APIClient
    /// Absolute (search artwork) or server-relative (album cover). nil means the
    /// server sent no URL.
    let reference: String?
    let side: CGFloat
    @Binding var failure: APIError?

    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case noReference
        case loaded(UIImage)
        case failed
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.35))
            switch phase {
            case .loading:
                ProgressView()
            case .noReference:
                Image(systemName: "music.note")
                    .foregroundStyle(Color.white.opacity(0.7))
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.white.opacity(0.8))
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: reference) {
            await load()
        }
    }

    private func load() async {
        guard let reference else {
            phase = .noReference
            failure = nil
            return
        }
        phase = .loading
        failure = nil
        do {
            let url = try client.resolve(reference)
            let data = try await client.imageData(at: url)
            guard let image = UIImage(data: data) else {
                throw APIError.undecodableImage(url: url, byteCount: data.count)
            }
            phase = .loaded(image)
        } catch {
            let apiError = APIError.from(error)
            // SwiftUI cancels this task when the row scrolls off screen, and runs
            // it again when the row comes back. That is not a failure to report:
            // the image box stays in `loading` and reloads on reappearance.
            if apiError.isCancellation && Task.isCancelled {
                return
            }
            phase = .failed
            failure = apiError
        }
    }
}
