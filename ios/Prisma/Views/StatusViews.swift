import Foundation
import SwiftUI
import UIKit

/// The whole error, selectable and copyable, so it can be read off the phone and
/// pasted into a bug report.
struct ErrorReport: View {
    let error: APIError

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error.title, systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(error.detailText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy error text") {
                UIPasteboard.general.string = error.fullText
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// A spinner with a running seconds counter and the timeout, so a slow request is
/// visibly different from a hung one.
struct LoadingRow: View {
    let message: String
    let since: Date
    let timeout: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            HStack(spacing: 12) {
                ProgressView()
                Text("\(message) \(max(0, Int(context.date.timeIntervalSince(since))))s. Gives up after \(Int(timeout))s with no response.")
            }
        }
    }
}

/// Label above value, never truncated.
struct FieldRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum Formatting {
    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "duration unknown" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func bytes(_ count: Int?) -> String {
        guard let count else { return "size unknown" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)) (\(count) bytes)"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func serverLine(_ savedAddress: String) -> String {
        savedAddress.isEmpty ? "Server: not set. Set it in Settings." : "Server: \(savedAddress)"
    }
}
