import Foundation
import Observation
import SwiftUI

/// Spec 5.2.
nonisolated enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
    case adaptive
    case preset
    case monoDark
    case monoLight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adaptive: return "Adaptive"
        case .preset: return "Preset"
        case .monoDark: return "Black"
        case .monoLight: return "White"
        }
    }
}

/// How the surfaces behind and around content are drawn.
nonisolated struct SurfaceStyle: Equatable, Sendable {
    let background: RGBColor
    /// Light only for mono-light. Glass follows it, which is how its polarity
    /// inverts (spec 5.5): system material, not hand-painted.
    let colorScheme: ColorScheme
    let showsAura: Bool
    /// Scrim opacity at the top of the screen; nil where spec 5.6 says there is none.
    let scrimTop: Double?
    let scrimBottom: Double?
}

/// Everything the theme currently draws, plus why.
nonisolated struct ResolvedTheme: Equatable, Sendable {
    let mode: ThemeMode
    /// The colours actually drawn.
    let palette: AuraPalette
    /// The colours as received, before the lightness clamp. Adaptive only.
    let incoming: AuraPalette?
    let source: String
    let problem: String?
    let luminance: Double
    let surface: SurfaceStyle
}

/// The rules of spec 5.2, 5.5 and 5.6 as pure functions.
nonisolated enum ThemeResolver {
    /// Same ceiling as the backend's MAX_LIGHTNESS in app/palette.py.
    static let maxLightness = 0.70
    /// Spec 5.6.
    static let scrimMinimum = 0.42
    static let scrimMaximum = 0.78
    /// Mean luminance at and below which the scrim is at its minimum, and at and
    /// above which it is at its maximum. Chosen so the Prisma preset gets 0.50, the
    /// prototype's value, and a white cover (after the clamp) reaches the maximum.
    static let luminanceAtMinimum = 0.27
    static let luminanceAtMaximum = 0.45
    /// The prototype's scrim is a gradient, 0.50 at the top to 0.80 at the bottom.
    static let scrimBottomLift = 0.30
    static let scrimBottomCeiling = 0.95

    nonisolated enum AdaptiveSource: Equatable, Sendable {
        case nothingPlaying
        case track(title: String, album: String?, palette: [String]?)
        case test(NamedPalette)
    }

    static func scrimOpacity(forLuminance luminance: Double) -> Double {
        let span = luminanceAtMaximum - luminanceAtMinimum
        let t = min(1, max(0, (luminance - luminanceAtMinimum) / span))
        return scrimMinimum + (scrimMaximum - scrimMinimum) * t
    }

    private typealias Choice = (palette: AuraPalette, incoming: AuraPalette?, source: String, problem: String?)

    static func resolve(mode: ThemeMode, preset: NamedPalette, adaptive: AdaptiveSource) -> ResolvedTheme {
        let choice: Choice
        switch mode {
        case .preset:
            let parsed = presetPalette(preset)
            choice = (parsed.palette, nil, "Preset \(preset.name)", parsed.problem)
        case .monoDark, .monoLight:
            let parsed = presetPalette(preset)
            choice = (parsed.palette, nil, "None: \(mode.label) is a flat theme without an aura", parsed.problem)
        case .adaptive:
            choice = adaptiveChoice(adaptive)
        }

        let luminance = choice.palette.meanLuminance
        let surface: SurfaceStyle
        switch mode {
        case .adaptive, .preset:
            let top = scrimOpacity(forLuminance: luminance)
            surface = SurfaceStyle(
                background: ThemeCatalog.auraBackground,
                colorScheme: .dark,
                showsAura: true,
                scrimTop: top,
                scrimBottom: min(scrimBottomCeiling, top + scrimBottomLift)
            )
        case .monoDark:
            surface = SurfaceStyle(background: ThemeCatalog.monoDarkBackground, colorScheme: .dark,
                                   showsAura: false, scrimTop: nil, scrimBottom: nil)
        case .monoLight:
            surface = SurfaceStyle(background: ThemeCatalog.monoLightBackground, colorScheme: .light,
                                   showsAura: false, scrimTop: nil, scrimBottom: nil)
        }

        return ResolvedTheme(
            mode: mode, palette: choice.palette, incoming: choice.incoming, source: choice.source,
            problem: choice.problem, luminance: luminance, surface: surface
        )
    }

    /// Where the adaptive palette comes from. With nothing playing, or an album
    /// without a palette, it is the Prisma preset (spec 5.2).
    private static func adaptiveChoice(_ adaptive: AdaptiveSource) -> Choice {
        switch adaptive {
        case .nothingPlaying:
            let prisma = prismaPalette()
            return (prisma.palette, nil, "Prisma preset: nothing is playing", prisma.problem)
        case .track(let title, let album, let hexes):
            guard let hexes else {
                let prisma = prismaPalette()
                return (prisma.palette, nil, "Prisma preset: the album of “\(title)” has no palette", prisma.problem)
            }
            return incomingChoice(label: "“\(title)” (\(album ?? "no album"))", hexes: hexes)
        case .test(let named):
            return incomingChoice(label: "Test palette \(named.name)", hexes: named.hexes)
        }
    }

    /// Colours from outside (the server, or a test): parsed, then clamped in lightness.
    private static func incomingChoice(label: String, hexes: [String]) -> Choice {
        switch AuraPalette.parse(hexes) {
        case .success(let parsed):
            return (parsed.clampingLightness(to: maxLightness), parsed, label, nil)
        case .failure(let failure):
            let prisma = prismaPalette()
            let problems = [failure.message, prisma.problem].compactMap { $0 }
            return (prisma.palette, nil, "Prisma preset: the palette of \(label) could not be used",
                    problems.joined(separator: " "))
        }
    }

    private static func prismaPalette() -> (palette: AuraPalette, problem: String?) {
        guard let prisma = ThemeCatalog.preset(id: ThemeCatalog.defaultPresetID) else {
            return (ThemeCatalog.fallbackPalette, "The Prisma preset is missing from the catalogue; drawing built-in colours.")
        }
        return presetPalette(prisma)
    }

    /// Presets are used exactly as in spec 5.3: never clamped.
    private static func presetPalette(_ named: NamedPalette) -> (palette: AuraPalette, problem: String?) {
        switch named.parsed {
        case .success(let parsed):
            return (parsed, nil)
        case .failure(let failure):
            return (ThemeCatalog.fallbackPalette,
                    "Preset \(named.name) is invalid: \(failure.message). Drawing built-in Prisma colours instead.")
        }
    }
}

/// Owns the theme for the app's lifetime. The mode and preset persist; a test
/// palette from the inspector does not.
@Observable
final class ThemeEngine {
    private static let modeKey = "theme.mode"
    private static let presetKey = "theme.preset"

    private(set) var mode: ThemeMode
    private(set) var presetID: String
    /// Set by the development inspector; overrides the playing track in adaptive mode.
    private(set) var testPalette: NamedPalette?
    /// A stored setting that could not be read at launch.
    private(set) var settingsProblem: String?

    @ObservationIgnored private let playback: PlaybackEngine

    init(playback: PlaybackEngine) {
        self.playback = playback
        let defaults = UserDefaults.standard
        var problems: [String] = []

        let storedMode = defaults.string(forKey: Self.modeKey)
        if let storedMode, let parsed = ThemeMode(rawValue: storedMode) {
            mode = parsed
        } else {
            mode = .adaptive
            if let storedMode {
                problems.append("The saved mode \"\(storedMode)\" is unknown; using Adaptive.")
            }
        }

        let storedPreset = defaults.string(forKey: Self.presetKey)
        if let storedPreset, ThemeCatalog.preset(id: storedPreset) != nil {
            presetID = storedPreset
        } else {
            presetID = ThemeCatalog.defaultPresetID
            if let storedPreset {
                problems.append("The saved preset \"\(storedPreset)\" is unknown; using Prisma.")
            }
        }
        settingsProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    var preset: NamedPalette {
        ThemeCatalog.preset(id: presetID)
            ?? NamedPalette(id: presetID, name: presetID, hexes: [], purpose: "")
    }

    /// Recomputed whenever the mode, preset, test palette or playing track changes.
    var resolved: ResolvedTheme {
        let adaptive: ThemeResolver.AdaptiveSource
        if let testPalette {
            adaptive = .test(testPalette)
        } else if let track = playback.currentTrack {
            adaptive = .track(
                title: track.title ?? track.serverID,
                album: track.album?.title,
                palette: track.album?.palette
            )
        } else {
            adaptive = .nothingPlaying
        }
        return ThemeResolver.resolve(mode: mode, preset: preset, adaptive: adaptive)
    }

    func setMode(_ newMode: ThemeMode) {
        mode = newMode
        if newMode != .adaptive {
            testPalette = nil
        }
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeKey)
    }

    func setPreset(id: String) {
        guard ThemeCatalog.preset(id: id) != nil else {
            settingsProblem = "Preset \"\(id)\" does not exist."
            return
        }
        presetID = id
        UserDefaults.standard.set(id, forKey: Self.presetKey)
    }

    /// Switches to adaptive mode and feeds it `palette` instead of the playing track.
    func applyTestPalette(_ palette: NamedPalette) {
        testPalette = palette
        setMode(.adaptive)
    }

    func clearTestPalette() {
        testPalette = nil
    }
}
