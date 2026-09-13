import Foundation
import SwiftData
import SwiftUI

/// Above the tab bar: artwork, title, artist, play/pause and next. Tapping the
/// track opens the full player. Also shows a playback error when nothing is loaded,
/// so a failure is never hidden along with the player.
struct MiniPlayerView: View {
    let openPlayer: () -> Void

    @Environment(PlaybackEngine.self) private var playback

    var body: some View {
        if let track = playback.currentTrack {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    Button(action: openPlayer) {
                        HStack(spacing: 12) {
                            PlayerArtwork(album: track.album, side: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title ?? "(no title)")
                                    .lineLimit(1)
                                Text(track.album?.artist ?? "")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                    Button {
                        playback.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!playback.hasNext)
                    .accessibilityLabel("Next track")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                if let error = playback.lastError {
                    Button(action: openPlayer) {
                        Text("Playback error: \(error.title). Tap for details.")
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
            }
            .background(.background)
        } else if let error = playback.lastError {
            VStack(spacing: 0) {
                Divider()
                Button(action: openPlayer) {
                    Text("Playback error: \(error.title). Tap for details.")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding()
            }
            .background(.background)
        }
    }
}

/// Full-screen player: seek slider, elapsed and remaining time, previous, play
/// and next, shuffle and repeat, and every message and error from playback.
struct FullPlayerView: View {
    @Environment(PlaybackEngine.self) private var playback
    @Environment(\.dismiss) private var dismiss

    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0

    var body: some View {
        NavigationStack {
            List {
                if let track = playback.currentTrack {
                    Section {
                        HStack {
                            Spacer()
                            PlayerArtwork(album: track.album, side: 260)
                            Spacer()
                        }
                        Text(track.title ?? "(no title)")
                            .font(.title2)
                        Text(track.album?.artist ?? "Unknown artist")
                        Text(track.album?.title ?? "No album")
                            .font(.subheadline)
                        if let index = playback.currentIndex {
                            Text("Track \(index + 1) of \(playback.queue.count) in the queue")
                                .font(.caption)
                        }
                        if let problem = playback.artworkProblem {
                            Text(problem)
                                .font(.caption2)
                        }
                    }

                    Section {
                        Slider(
                            value: Binding(
                                get: { scrubbing ? scrubPosition : playback.elapsed },
                                set: { scrubPosition = $0 }
                            ),
                            in: 0...max(playback.duration, 1),
                            onEditingChanged: { editing in
                                if editing {
                                    scrubPosition = playback.elapsed
                                    scrubbing = true
                                } else {
                                    playback.seek(to: scrubPosition)
                                    scrubbing = false
                                }
                            }
                        )
                        let shown = scrubbing ? scrubPosition : playback.elapsed
                        HStack {
                            Text(Formatting.clock(shown))
                            Spacer()
                            Text("-" + Formatting.clock(max(0, playback.duration - shown)))
                        }
                        .font(.caption.monospacedDigit())

                        HStack(spacing: 44) {
                            Spacer()
                            Button {
                                playback.previous()
                            } label: {
                                Image(systemName: "backward.fill")
                            }
                            .accessibilityLabel("Previous track")
                            Button {
                                playback.togglePlayPause()
                            } label: {
                                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            }
                            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                            Button {
                                playback.next()
                            } label: {
                                Image(systemName: "forward.fill")
                            }
                            .disabled(!playback.hasNext)
                            .accessibilityLabel("Next track")
                            Spacer()
                        }
                        .font(.largeTitle)
                        .buttonStyle(.borderless)
                        .padding(.vertical, 8)
                    }

                    Section {
                        Toggle("Shuffle", isOn: Binding(
                            get: { playback.shuffle },
                            set: { playback.setShuffle($0) }
                        ))
                        Picker("Repeat", selection: Binding(
                            get: { playback.repeatMode },
                            set: { playback.setRepeat($0) }
                        )) {
                            ForEach(PlaybackEngine.RepeatMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("Nothing is playing. Tap a downloaded track in the Library tab.")
                    }
                }

                if let message = playback.message {
                    Section {
                        Text(message)
                        Button("Dismiss") { playback.clearMessage() }
                    } header: {
                        Text("Playback").textCase(nil)
                    }
                }

                if let error = playback.lastError {
                    Section {
                        ErrorReport(error: error)
                        Button("Dismiss error") { playback.clearError() }
                    } header: {
                        Text("Playback error").textCase(nil)
                    }
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// An album cover from local storage, or a plain placeholder.
private struct PlayerArtwork: View {
    let album: StoredAlbum?
    let side: CGFloat

    @State private var problem: String?

    var body: some View {
        if let album {
            LocalCoverImage(album: album, side: side, problem: $problem)
        } else {
            ZStack {
                Rectangle()
                    .fill(.quaternary)
                Text("no album")
                    .font(.caption2)
            }
            .frame(width: side, height: side)
        }
    }
}
