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
        case .adaptive: return "Adattivo"
        case .preset: return "Preset"
        case .monoDark: return "Nero"
        case .monoLight: return "Bianco"
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
    /// The single scrim value computed from the palette's luminance. nil where
    /// spec 5.6 says there is no scrim.
    let scrimBase: Double?
    /// The opacities actually drawn: the base spread around itself, never above
    /// the ceiling.
    let scrimTop: Double?
    let scrimBottom: Double?
}

/// Everything the theme currently draws, plus why.
nonisolated struct ResolvedTheme: Equatable, Sendable {
    let mode: ThemeMode
    /// The colours actually drawn.
    let palette: AuraPalette
    /// Adaptive only: the colours as received, and after the lightness clamp but
    /// before the saturation boost.
    let incoming: AuraPalette?
    let clamped: AuraPalette?
    let source: String
    let problem: String?
    let luminance: Double
    let surface: SurfaceStyle
}

/// The rules of spec 5.2, 5.5 and 5.6 as pure functions.
nonisolated enum ThemeResolver {
    /// Same ceiling as the backend's MAX_LIGHTNESS in app/palette.py.
    static let maxLightness = 0.70
    /// After the clamp, saturation moves this fraction of the way to fully
    /// saturated, so a clamped light palette stays colourful instead of going grey.
    static let saturationBoost = 0.45
    /// Below this HLS saturation a colour is a grey with no hue to boost.
    static let greySaturation = 0.02

    /// Spec 5.6 floor for the computed scrim value.
    static let scrimMinimum = 0.42
    /// Nothing drawn exceeds this. Lowered from the spec's 0.78: the lightness clamp
    /// already darkens the worst palettes, so the scrim does not compensate twice.
    static let scrimCeiling = 0.68
    /// The drawn gradient runs from base - spread at the top to base + spread at
    /// the bottom, clamped to the ceiling.
    static let scrimSpread = 0.10
    /// Mean luminance at and below which the base is at its floor, and at and above
    /// which it reaches the ceiling. Prisma (0.31) lands at 0.44, lighter than the
    /// 0.51 of build 11.
    static let luminanceAtMinimum = 0.30
    static let luminanceAtMaximum = 0.50

    /// The scrim colour, prototype --bg.
    static let scrimColor = ThemeCatalog.auraBackground

    nonisolated enum AdaptiveSource: Equatable, Sendable {
        case nothingPlaying
        case track(title: String, album: String?, palette: [String]?)
        case test(NamedPalette)
    }

    static func scrimBase(forLuminance luminance: Double) -> Double {
        let span = luminanceAtMaximum - luminanceAtMinimum
        let t = min(1, max(0, (luminance - luminanceAtMinimum) / span))
        return scrimMinimum + (scrimCeiling - scrimMinimum) * t
    }

    static func scrimTop(base: Double) -> Double {
        min(scrimCeiling, max(0, base - scrimSpread))
    }

    static func scrimBottom(base: Double) -> Double {
        min(scrimCeiling, max(0, base + scrimSpread))
    }

    /// `color` seen through the scrim at `opacity`.
    static func composite(_ color: RGBColor, scrimOpacity opacity: Double) -> RGBColor {
        RGBColor(
            red: color.red * (1 - opacity) + scrimColor.red * opacity,
            green: color.green * (1 - opacity) + scrimColor.green * opacity,
            blue: color.blue * (1 - opacity) + scrimColor.blue * opacity
        )
    }

    /// WCAG contrast ratio of white text on `background`.
    static func whiteTextContrast(on background: RGBColor) -> Double {
        1.05 / (background.relativeLuminance + 0.05)
    }

    private typealias Choice = (palette: AuraPalette, incoming: AuraPalette?, clamped: AuraPalette?, source: String, problem: String?)

    static func resolve(mode: ThemeMode, preset: NamedPalette, adaptive: AdaptiveSource) -> ResolvedTheme {
        let choice: Choice
        switch mode {
        case .preset:
            let parsed = presetPalette(preset)
            choice = (parsed.palette, nil, nil, "Preset \(preset.name)", parsed.problem)
        case .monoDark, .monoLight:
            let parsed = presetPalette(preset)
            choice = (parsed.palette, nil, nil, "Nessuna: \(mode.label) è un tema piatto senza aura", parsed.problem)
        case .adaptive:
            choice = adaptiveChoice(adaptive)
        }

        let luminance = choice.palette.meanLuminance
        let surface: SurfaceStyle
        switch mode {
        case .adaptive, .preset:
            let base = scrimBase(forLuminance: luminance)
            surface = SurfaceStyle(
                background: ThemeCatalog.auraBackground,
                colorScheme: .dark,
                showsAura: true,
                scrimBase: base,
                scrimTop: scrimTop(base: base),
                scrimBottom: scrimBottom(base: base)
            )
        case .monoDark:
            surface = SurfaceStyle(background: ThemeCatalog.monoDarkBackground, colorScheme: .dark,
                                   showsAura: false, scrimBase: nil, scrimTop: nil, scrimBottom: nil)
        case .monoLight:
            surface = SurfaceStyle(background: ThemeCatalog.monoLightBackground, colorScheme: .light,
                                   showsAura: false, scrimBase: nil, scrimTop: nil, scrimBottom: nil)
        }

        return ResolvedTheme(
            mode: mode, palette: choice.palette, incoming: choice.incoming, clamped: choice.clamped,
            source: choice.source, problem: choice.problem, luminance: luminance, surface: surface
        )
    }

    /// Where the adaptive palette comes from. With nothing playing, or an album
    /// without a palette, it is the Prisma preset (spec 5.2).
    private static func adaptiveChoice(_ adaptive: AdaptiveSource) -> Choice {
        switch adaptive {
        case .nothingPlaying:
            let prisma = prismaPalette()
            return (prisma.palette, nil, nil, "Preset Prisma: non c'è niente in riproduzione", prisma.problem)
        case .track(let title, let album, let hexes):
            guard let hexes else {
                let prisma = prismaPalette()
                return (prisma.palette, nil, nil, "Preset Prisma: l'album di “\(title)” non ha una palette", prisma.problem)
            }
            return incomingChoice(label: "“\(title)” (\(album ?? "senza album"))", hexes: hexes)
        case .test(let named):
            return incomingChoice(label: "Palette di prova \(named.name)", hexes: named.hexes)
        }
    }

    /// Colours from outside (the server, or a test): parsed, clamped in lightness,
    /// then boosted in saturation.
    private static func incomingChoice(label: String, hexes: [String]) -> Choice {
        switch AuraPalette.parse(hexes) {
        case .success(let parsed):
            let clamped = parsed.clampingLightness(to: maxLightness)
            let boosted = clamped.boostingSaturation(by: saturationBoost, greyThreshold: greySaturation)
            return (boosted, parsed, clamped, label, nil)
        case .failure(let failure):
            let prisma = prismaPalette()
            let problems = [failure.message, prisma.problem].compactMap { $0 }
            return (prisma.palette, nil, nil, "Preset Prisma: la palette di \(label) non è utilizzabile",
                    problems.joined(separator: " "))
        }
    }

    private static func prismaPalette() -> (palette: AuraPalette, problem: String?) {
        guard let prisma = ThemeCatalog.preset(id: ThemeCatalog.defaultPresetID) else {
            return (ThemeCatalog.fallbackPalette, "Il preset Prisma manca dal catalogo: vengono usati i colori incorporati.")
        }
        return presetPalette(prisma)
    }

    /// Presets are used exactly as in spec 5.3: never clamped or boosted.
    private static func presetPalette(_ named: NamedPalette) -> (palette: AuraPalette, problem: String?) {
        switch named.parsed {
        case .success(let parsed):
            return (parsed, nil)
        case .failure(let failure):
            return (ThemeCatalog.fallbackPalette,
                    "Il preset \(named.name) non è valido (\(failure.message)): vengono usati i colori incorporati di Prisma.")
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
                problems.append("La modalità salvata “\(storedMode)” non esiste più: viene usato Adattivo. Sceglila di nuovo in Impostazioni.")
            }
        }

        let storedPreset = defaults.string(forKey: Self.presetKey)
        if let storedPreset, ThemeCatalog.preset(id: storedPreset) != nil {
            presetID = storedPreset
        } else {
            presetID = ThemeCatalog.defaultPresetID
            if let storedPreset {
                problems.append("Il preset salvato “\(storedPreset)” non esiste più: viene usato Prisma. Sceglilo di nuovo in Impostazioni.")
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
            settingsProblem = "Il preset “\(id)” non esiste: scegline un altro."
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
