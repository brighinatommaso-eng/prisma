import Foundation
import SwiftUI

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
    /// "3:07"; empty when the server sent no duration.
    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// For internal error records only, never shown.
    static func bytes(_ count: Int?) -> String {
        guard let count else { return "size unknown" }
        return "\(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)) (\(count) bytes)"
    }

    /// "3:07" for a playback position.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
