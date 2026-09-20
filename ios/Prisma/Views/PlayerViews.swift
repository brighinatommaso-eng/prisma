import AVKit
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Whether the full-screen player is showing, and where playback was started from.
/// Shared so any screen, including ones pushed inside a tab, can host the mini player.
@Observable
final class PlayerPresenter {
    var isPresented = false
    /// The playlist playback was started from, for "In riproduzione da". nil means
    /// the album of the playing track. Kept in memory only: after a relaunch the
    /// restored queue shows its album.
    var sourceName: String?
}

/// Puts the mini player above the tab bar and shrinks the safe area beneath it,
/// so the last row of a list scrolls clear. Apply it to a tab's root screen and to
/// every screen pushed inside a tab, inside the NavigationStack: applied outside,
/// the inset never reaches the List (build 8).
struct MiniPlayerInset: ViewModifier {
    @Environment(PlayerPresenter.self) private var presenter

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView {
                presenter.isPresented = true
            }
        }
    }
}

extension View {
    func miniPlayerInset() -> some View {
        modifier(MiniPlayerInset())
    }
}

// MARK: - Mini player

/// Prototype `.mini`: a floating glass bar with artwork, title, artist, the heart,
/// play/pause and next, and a thin progress line. Tapping the track opens the full
/// player. A playback error shows even when nothing is loaded, so a failure is never
/// hidden along with the player.
struct MiniPlayerView: View {
    let openPlayer: () -> Void

    @Environment(PlaybackEngine.self) private var playback
    @Environment(\.prismaInk) private var ink

    var body: some View {
        // The one place this view reads the store: the engine's fetch, projected
        // before anything below it sees the result.
        if let track = playback.currentTrack.map({ Projection.row(of: $0) }) {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button(action: openPlayer) {
                        HStack(spacing: 11) {
                            CoverArt(cover: track.cover, side: 42, cornerRadius: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.title)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(ink.primary)
                                    .lineLimit(1)
                                Text(track.artist ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(ink.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 62)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Apre il player")

                    FavouriteButton(draft: track.favouriteDraft, isFavourite: track.isFavourite,
                                    hitSize: CGSize(width: 44, height: 46), glyphSize: 17)

                    // Each control is its own button with the whole square as its hit
                    // area; a plain button otherwise only responds on the glyph.
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(ink.primary)
                            .frame(width: 46, height: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.isPlaying ? "Pausa" : "Riproduci")

                    Button {
                        playback.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(ink.primary)
                            .frame(width: 46, height: 46)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!playback.hasNext)
                    .opacity(playback.hasNext ? 1 : 0.45)
                    .accessibilityLabel("Brano successivo")
                }
                .padding(.leading, 11)
                .padding(.trailing, 4)

                if playback.lastError != nil {
                    errorLine
                }
            }
            .overlay(alignment: .bottom) {
                progressLine
            }
            .prismaGlass(RoundedRectangle(cornerRadius: 22))
            .padding(.horizontal, 13)
            .padding(.bottom, 6)
        } else if playback.lastError != nil {
            errorLine
                .padding(.vertical, 6)
                .prismaGlass(RoundedRectangle(cornerRadius: 22))
                .padding(.horizontal, 13)
                .padding(.bottom, 6)
        }
    }

    private var errorLine: some View {
        Button(action: openPlayer) {
            Label("Errore di riproduzione · tocca per sapere perché", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(ink.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
    }

    /// Prototype `.mprog`.
    private var progressLine: some View {
        let fraction = playback.duration > 0 ? min(1, max(0, playback.elapsed / playback.duration)) : 0
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(ink.primary.opacity(0.14))
                Rectangle()
                    .fill(ink.primary.opacity(0.8))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 11)
        .accessibilityHidden(true)
    }
}

// MARK: - Full player

/// Prototype player: context line with close and overflow, large artwork, title and
/// artist with the heart, seek bar, transport, and queue and AirPlay at the bottom.
/// The large play button is the only glass on this screen (spec 5.8).
struct FullPlayerView: View {
    @Environment(PlaybackEngine.self) private var playback
    @Environment(PlayerPresenter.self) private var presenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.prismaInk) private var ink

    @State private var showingQueue = false
    @State private var addingToPlaylist = false

    var body: some View {
        // The one place this screen reads the store.
        let track = playback.currentTrack.map { Projection.row(of: $0) }

        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if let track {
                        topBar(source: presenter.sourceName ?? track.albumTitle ?? "Libreria")
                        nowPlaying(track, width: proxy.size.width - 52, height: proxy.size.height)
                    } else {
                        topBar(source: nil)
                        Text("Non c'è niente in riproduzione. Tocca un brano scaricato in Libreria.")
                            .font(.subheadline)
                            .foregroundStyle(ink.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 60)
                    }

                    messages
                        .padding(.top, 16)

                    Spacer(minLength: 16)

                    bottomRow
                }
                .padding(.horizontal, 26)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .themedScreenBackground()
        .sheet(isPresented: $showingQueue) {
            QueueSheet()
        }
        .sheet(isPresented: $addingToPlaylist) {
            // The id, which the engine holds anyway: the sheet outlives the track it
            // was opened for, and resolves it itself.
            if let id = playback.currentTrackID {
                AddToPlaylistSheet(trackID: id)
            }
        }
    }

    /// Prototype `.ptop`.
    private func topBar(source: String?) -> some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ink.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Chiudi il player")

            Spacer(minLength: 8)

            if let source {
                VStack(spacing: 2) {
                    Text("In riproduzione da")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.3)
                        .textCase(.uppercase)
                        .foregroundStyle(ink.secondary)
                    Text(source)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ink.primary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 8)

            Menu {
                Button {
                    addingToPlaylist = true
                } label: {
                    Label("Aggiungi a playlist…", systemImage: "text.badge.plus")
                }
                .disabled(playback.currentTrack == nil)
                Button {
                    showingQueue = true
                } label: {
                    Label("Coda", systemImage: "list.bullet")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ink.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Altre azioni")
        }
    }

    @ViewBuilder
    private func nowPlaying(_ track: TrackRowData, width: CGFloat, height: CGFloat) -> some View {
        let side = max(120, min(width, height * 0.45))

        // Prototype `.part`: large, radius 24, deep shadow.
        CoverArt(cover: track.cover, side: side, cornerRadius: 24)
            .shadow(color: .black.opacity(0.7), radius: 32, y: 24)
            .padding(.top, 22)

        // Prototype `.prow`.
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(ink.primary)
                    .lineLimit(2)
                Text(track.artist ?? "Artista sconosciuto")
                    .font(.subheadline)
                    .foregroundStyle(ink.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            FavouriteButton(draft: track.favouriteDraft, isFavourite: track.isFavourite, glyphSize: 23)
                .padding(.bottom, -6)
        }
        .padding(.top, 28)

        SeekBar(elapsed: playback.elapsed, duration: playback.duration) { seconds in
            playback.seek(to: seconds)
        }
        .padding(.top, 14)

        transport
            .padding(.top, 12)

        if let problem = playback.artworkProblem {
            ProblemBlock(problem)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
        }
    }

    /// Prototype `.trans`: shuffle, previous, play, next, repeat.
    private var transport: some View {
        HStack(spacing: 0) {
            smallControl(
                "shuffle",
                active: playback.shuffle,
                label: playback.shuffle ? "Casuale attivo" : "Casuale disattivo"
            ) {
                playback.setShuffle(!playback.shuffle)
            }
            Spacer(minLength: 0)
            Button {
                playback.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(ink.primary)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Brano precedente")
            Spacer(minLength: 0)
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(ink.primary)
                    .frame(width: 58, height: 58)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(playback.isPlaying ? "Pausa" : "Riproduci")
            Spacer(minLength: 0)
            Button {
                playback.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(ink.primary)
                    .frame(width: 46, height: 46)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!playback.hasNext)
            .opacity(playback.hasNext ? 1 : 0.45)
            .accessibilityLabel("Brano successivo")
            Spacer(minLength: 0)
            smallControl(
                playback.repeatMode == .one ? "repeat.1" : "repeat",
                active: playback.repeatMode != .off,
                label: repeatLabel
            ) {
                playback.setRepeat(nextRepeatMode)
            }
        }
    }

    private var repeatLabel: String {
        switch playback.repeatMode {
        case .off: return "Ripeti disattivo"
        case .all: return "Ripeti la coda"
        case .one: return "Ripeti il brano"
        }
    }

    private var nextRepeatMode: PlaybackEngine.RepeatMode {
        switch playback.repeatMode {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    private func smallControl(_ systemName: String, active: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? ink.accent : ink.secondary)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// What the engine did on its own, and playback errors.
    @ViewBuilder
    private var messages: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let message = playback.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ink.secondary)
                DismissLink { playback.clearMessage() }
            }
            if let error = playback.lastError {
                ProblemBlock(PlainLanguage.message(for: error))
                DismissLink { playback.clearError() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Prototype `.pbot`: queue and AirPlay.
    private var bottomRow: some View {
        HStack {
            Button {
                showingQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(ink.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Coda")
            Spacer()
            AirPlayButton(tint: UIColor(red: ink.secondaryRGB.red, green: ink.secondaryRGB.green, blue: ink.secondaryRGB.blue, alpha: 1))
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
        }
    }
}

/// Prototype `.seek`: a 5 pt track with a knob, over a 44 pt touch area, and the
/// elapsed and remaining times. Adjustable with VoiceOver in 10 s steps.
private struct SeekBar: View {
    let elapsed: TimeInterval
    let duration: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @Environment(\.prismaInk) private var ink
    @State private var dragFraction: Double?

    var body: some View {
        let shown = dragFraction.map { $0 * duration } ?? elapsed
        let fraction = duration > 0 ? min(1, max(0, shown / duration)) : 0
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ink.primary.opacity(0.2))
                        .frame(height: 5)
                    Capsule()
                        .fill(ink.primary)
                        .frame(width: width * fraction, height: 5)
                    Circle()
                        .fill(ink.primary)
                        .frame(width: 12, height: 12)
                        .offset(x: width * fraction - 6)
                }
                .frame(width: width, height: proxy.size.height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(1, max(0, value.location.x / width))
                        }
                        .onEnded { value in
                            let released = min(1, max(0, value.location.x / width))
                            dragFraction = nil
                            if duration > 0 {
                                onSeek(released * duration)
                            }
                        }
                )
            }
            .frame(height: 44)

            HStack {
                Text(Formatting.clock(shown))
                Spacer()
                Text("-" + Formatting.clock(max(0, duration - shown)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(ink.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Posizione nel brano")
        .accessibilityValue("\(Formatting.clock(shown)) di \(Formatting.clock(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onSeek(min(duration, elapsed + 10))
            case .decrement:
                onSeek(max(0, elapsed - 10))
            @unknown default:
                break
            }
        }
    }
}

/// The play queue in order, the current track marked by the equaliser.
private struct QueueSheet: View {
    @Environment(PlaybackEngine.self) private var playback
    @Environment(\.dismiss) private var dismiss
    @Query private var tracks: [StoredTrack]

    var body: some View {
        // The one place this sheet reads the store.
        let rows = Projection.queue(ids: playback.queue, tracks: tracks)
        NavigationStack {
            List {
                if rows.isEmpty {
                    Text("La coda è vuota.")
                }
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Text("\(row.id + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                                .lineLimit(1)
                            Text(row.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if row.id == playback.currentIndex {
                            EqualizerBars(isAnimating: playback.isPlaying)
                        }
                    }
                    .frame(minHeight: 44)
                }
            }
            .navigationTitle("Coda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}

/// The system AirPlay route picker.
private struct AirPlayButton: UIViewRepresentable {
    let tint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = tint
        view.activeTintColor = tint
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = tint
    }
}
