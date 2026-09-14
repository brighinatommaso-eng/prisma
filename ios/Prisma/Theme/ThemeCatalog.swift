import Foundation

/// An sRGB colour with components in 0...1.
nonisolated struct RGBColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#rrggbb", with or without the "#". nil for anything else; callers report it.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else {
            return nil
        }
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }

    var hex: String {
        String(format: "#%02x%02x%02x", Self.byte(red), Self.byte(green), Self.byte(blue))
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// HLS lightness, as Python's colorsys computes it on the backend.
    var lightness: Double {
        (max(red, green, blue) + min(red, green, blue)) / 2
    }

    /// Lowers HLS lightness to `maximum`, keeping hue and saturation. Mirrors the
    /// backend's `_clamp_lightness` in app/palette.py, including rounding to 8 bits,
    /// so both defences produce the same colour.
    func clampingLightness(to maximum: Double) -> RGBColor {
        let (hue, lightness, saturation) = hls
        guard lightness > maximum else { return self }
        let rgb = Self.rgb(hue: hue, lightness: maximum, saturation: saturation)
        return RGBColor(
            red: Double(Self.byte(rgb.0)) / 255,
            green: Double(Self.byte(rgb.1)) / 255,
            blue: Double(Self.byte(rgb.2)) / 255
        )
    }

    /// Moves HLS saturation `amount` of the way towards fully saturated, keeping hue
    /// and lightness. Greys (saturation below `greyThreshold`) have no hue and are
    /// returned unchanged.
    func boostingSaturation(by amount: Double, greyThreshold: Double) -> RGBColor {
        let (hue, lightness, saturation) = hls
        guard amount > 0, saturation >= greyThreshold else { return self }
        let boosted = min(1, saturation + (1 - saturation) * amount)
        let rgb = Self.rgb(hue: hue, lightness: lightness, saturation: boosted)
        return RGBColor(
            red: Double(Self.byte(rgb.0)) / 255,
            green: Double(Self.byte(rgb.1)) / 255,
            blue: Double(Self.byte(rgb.2)) / 255
        )
    }

    private static func byte(_ component: Double) -> Int {
        Int((min(1, max(0, component)) * 255).rounded())
    }

    // colorsys.rgb_to_hls
    private var hls: (Double, Double, Double) {
        let maxc = max(red, green, blue)
        let minc = min(red, green, blue)
        let lightness = (maxc + minc) / 2
        guard maxc != minc else { return (0, lightness, 0) }
        let range = maxc - minc
        let saturation = lightness <= 0.5 ? range / (maxc + minc) : range / (2 - maxc - minc)
        let rc = (maxc - red) / range
        let gc = (maxc - green) / range
        let bc = (maxc - blue) / range
        var hue: Double
        if red == maxc {
            hue = bc - gc
        } else if green == maxc {
            hue = 2 + rc - bc
        } else {
            hue = 4 + gc - rc
        }
        hue = Self.unit(hue / 6)
        return (hue, lightness, saturation)
    }

    // colorsys.hls_to_rgb
    private static func rgb(hue: Double, lightness: Double, saturation: Double) -> (Double, Double, Double) {
        guard saturation != 0 else { return (lightness, lightness, lightness) }
        let m2 = lightness <= 0.5 ? lightness * (1 + saturation) : lightness + saturation - lightness * saturation
        let m1 = 2 * lightness - m2
        func value(_ h: Double) -> Double {
            let h = unit(h)
            if h < 1.0 / 6 { return m1 + (m2 - m1) * h * 6 }
            if h < 0.5 { return m2 }
            if h < 2.0 / 3 { return m1 + (m2 - m1) * (2.0 / 3 - h) * 6 }
            return m1
        }
        return (value(hue + 1.0 / 3), value(hue), value(hue - 1.0 / 3))
    }

    private static func unit(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

/// The four aura sources.
nonisolated struct AuraPalette: Equatable, Sendable {
    let colors: [RGBColor]

    init(_ c1: RGBColor, _ c2: RGBColor, _ c3: RGBColor, _ c4: RGBColor) {
        colors = [c1, c2, c3, c4]
    }

    nonisolated struct Problem: Error, Equatable, Sendable {
        let message: String
    }

    /// Exactly four "#rrggbb" values, or a problem saying what is wrong.
    static func parse(_ hexes: [String]) -> Result<AuraPalette, Problem> {
        guard hexes.count == 4 else {
            return .failure(Problem(message: "Expected 4 colours, got \(hexes.count): \(hexes)"))
        }
        var colors: [RGBColor] = []
        for hex in hexes {
            guard let color = RGBColor(hex: hex) else {
                return .failure(Problem(message: "\"\(hex)\" is not a #rrggbb colour (in \(hexes))"))
            }
            colors.append(color)
        }
        return .success(AuraPalette(colors[0], colors[1], colors[2], colors[3]))
    }

    func clampingLightness(to maximum: Double) -> AuraPalette {
        let clamped = colors.map { $0.clampingLightness(to: maximum) }
        return AuraPalette(clamped[0], clamped[1], clamped[2], clamped[3])
    }

    func boostingSaturation(by amount: Double, greyThreshold: Double) -> AuraPalette {
        let boosted = colors.map { $0.boostingSaturation(by: amount, greyThreshold: greyThreshold) }
        return AuraPalette(boosted[0], boosted[1], boosted[2], boosted[3])
    }

    /// The colour with the highest relative luminance: the worst case for white text.
    var brightest: RGBColor {
        colors.max { $0.relativeLuminance < $1.relativeLuminance } ?? colors[0]
    }

    var meanLuminance: Double {
        colors.map(\.relativeLuminance).reduce(0, +) / Double(colors.count)
    }
}

/// A named set of four hex values: a preset from spec 5.3, or an inspector test palette.
nonisolated struct NamedPalette: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let hexes: [String]
    /// Why this test palette exists; empty for presets.
    let purpose: String

    var parsed: Result<AuraPalette, AuraPalette.Problem> {
        AuraPalette.parse(hexes)
    }
}

/// The single source of truth for theme data: spec 5.2 surfaces and the table in 5.3.
nonisolated enum ThemeCatalog {
    /// Spec table 5.3, in order. Prisma is the default and the adaptive fallback.
    static let presets: [NamedPalette] = [
        preset("prisma", "Prisma", "#1e26b6", "#e73b86", "#fba402", "#00d4c8"),
        preset("abisso", "Abisso", "#06283d", "#1363df", "#47b5ff", "#0a9396"),
        preset("brace", "Brace", "#7c2d12", "#dc2626", "#f59e0b", "#fde047"),
        preset("serra", "Serra", "#14532d", "#4d7c0f", "#84cc16", "#0f766e"),
        preset("cenere", "Cenere", "#312e40", "#4b5563", "#6b7280", "#94a3b8"),
        preset("aurora", "Aurora", "#134e4a", "#7c3aed", "#f472b6", "#22d3ee"),
        preset("nebulosa", "Nebulosa", "#2e1065", "#6d28d9", "#a78bfa", "#ec4899"),
        preset("agrume", "Agrume", "#b45309", "#f97316", "#facc15", "#65a30d"),
        preset("laguna", "Laguna", "#0c4a6e", "#0891b2", "#22d3ee", "#5eead4"),
        preset("vinile", "Vinile", "#451a03", "#92400e", "#d97706", "#fbbf24"),
        preset("neon", "Neon", "#c026d3", "#22d3ee", "#a3e635", "#f43f5e"),
        preset("crepuscolo", "Crepuscolo", "#1e1b4b", "#4338ca", "#f472b6", "#fb923c"),
    ]

    static let defaultPresetID = "prisma"

    static func preset(id: String) -> NamedPalette? {
        presets.first { $0.id == id }
    }

    /// Prisma's colours as numbers, used only if the preset table itself failed to
    /// parse, so the app still draws something while the inspector shows the problem.
    static let fallbackPalette = AuraPalette(
        RGBColor(red: 30.0 / 255, green: 38.0 / 255, blue: 182.0 / 255),
        RGBColor(red: 231.0 / 255, green: 59.0 / 255, blue: 134.0 / 255),
        RGBColor(red: 251.0 / 255, green: 164.0 / 255, blue: 2.0 / 255),
        RGBColor(red: 0, green: 212.0 / 255, blue: 200.0 / 255)
    )

    /// Background under the aura, and the scrim colour (prototype --bg #0B0710).
    static let auraBackground = RGBColor(red: 11.0 / 255, green: 7.0 / 255, blue: 16.0 / 255)
    /// Spec 5.2 Nero: #08090A.
    static let monoDarkBackground = RGBColor(red: 8.0 / 255, green: 9.0 / 255, blue: 10.0 / 255)
    /// Spec 5.2 Bianco: #EFEFF2.
    static let monoLightBackground = RGBColor(red: 239.0 / 255, green: 239.0 / 255, blue: 242.0 / 255)

    /// Synthetic palettes for the development inspector. They go through the same
    /// path as a palette from the server, lightness clamp included.
    static let testPalettes: [NamedPalette] = [
        NamedPalette(id: "test-white", name: "Near-white", hexes: ["#ffffff", "#fafafa", "#f4f1ea", "#eef2f7"],
                     purpose: "A white cover. The clamp must pull it down and the scrim must rise to its ceiling."),
        NamedPalette(id: "test-black", name: "Near-black", hexes: ["#000000", "#050507", "#0b0b0f", "#121212"],
                     purpose: "A black cover. The scrim should stay at its floor."),
        NamedPalette(id: "test-fluo", name: "Fluorescent", hexes: ["#39ff14", "#ff00ff", "#00ffff", "#ffff00"],
                     purpose: "Saturated neon. Lightness is only 0.5, so the clamp leaves it alone; the scrim must still rise."),
        NamedPalette(id: "test-amber", name: "Pale amber", hexes: ["#fde68a", "#fcd34d", "#fef3c7", "#fbbf24"],
                     purpose: "The spec's example: white text on light amber."),
        NamedPalette(id: "test-invalid", name: "Invalid data", hexes: ["#zzzzzz", "#123"],
                     purpose: "Malformed server data. Must fall back to Prisma and show the problem, not crash."),
    ]

    private static func preset(_ id: String, _ name: String, _ c1: String, _ c2: String, _ c3: String, _ c4: String) -> NamedPalette {
        NamedPalette(id: id, name: name, hexes: [c1, c2, c3, c4], purpose: "")
    }
}
