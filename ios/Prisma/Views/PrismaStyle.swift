import Foundation
import SwiftUI

// MARK: - Ink: text and accent colours with guaranteed contrast

/// The colours content is drawn in, chosen for the current theme so text stays
/// readable on the composited background.
///
/// The reference background is the worst case the theme can draw: in Adaptive and
/// Preset the brightest palette colour under the scrim at its lightest (the top),
/// in Nero and Bianco the flat background. Text colours are picked against it:
/// secondary text is the prototype's dimmed ink, raised until it reaches 4.5:1;
/// accents (checks, the equaliser, the heart) start from the palette colour and move
/// towards the ink until they reach 3:1 for graphics or 4.5:1 for text. Where even
/// full ink cannot reach the target, full ink is used: that is the most contrast the
/// view layer can give without changing the scrim.
nonisolated struct PrismaInk: Equatable, Sendable {
    static let textContrast = 4.5
    static let graphicContrast = 3.0
    /// Prototype `.dim` is 58% ink on dark; spec 5.5 gives 60% on Bianco.
    static let secondaryStartDark = 0.58
    static let secondaryStartLight = 0.60

    let isLight: Bool
    /// The background every colour below was checked against.
    let reference: RGBColor
    let primaryRGB: RGBColor
    let secondaryRGB: RGBColor
    /// Checks, the equaliser, progress rings: graphics, at least 3:1.
    let accentRGB: RGBColor
    /// Accent-coloured text, at least 4.5:1 where the ink allows it.
    let accentTextRGB: RGBColor
    let favouriteRGB: RGBColor

    static let darkInk = RGBColor(red: 1, green: 1, blue: 1)
    /// Spec 5.5: Bianco labels are #0d0d10.
    static let lightInk = RGBColor(red: 13.0 / 255, green: 13.0 / 255, blue: 16.0 / 255)

    static let fallback = PrismaInk(
        isLight: false,
        background: ThemeCatalog.monoDarkBackground,
        reference: ThemeCatalog.monoDarkBackground,
        accentSource: ThemeCatalog.fallbackPalette.colors[3],
        favouriteSource: ThemeCatalog.fallbackPalette.colors[1]
    )

    init(resolved: ResolvedTheme) {
        let reference: RGBColor
        if resolved.surface.showsAura, let top = resolved.surface.scrimTop {
            reference = ThemeResolver.composite(resolved.palette.brightest, scrimOpacity: top)
        } else {
            reference = resolved.surface.background
        }
        self.init(
            isLight: resolved.surface.colorScheme == .light,
            background: resolved.surface.background,
            reference: reference,
            accentSource: resolved.palette.colors[3],
            favouriteSource: resolved.palette.colors[1]
        )
    }

    init(isLight: Bool, background: RGBColor, reference: RGBColor, accentSource: RGBColor, favouriteSource: RGBColor) {
        let ink = isLight ? Self.lightInk : Self.darkInk
        self.isLight = isLight
        self.reference = reference
        primaryRGB = ink
        secondaryRGB = Self.reaching(
            Self.textContrast, from: background, toward: ink, startingAt: isLight ? Self.secondaryStartLight : Self.secondaryStartDark,
            on: reference, isLight: isLight
        )
        accentRGB = Self.reaching(Self.graphicContrast, from: accentSource, toward: ink, startingAt: 0, on: reference, isLight: isLight)
        accentTextRGB = Self.reaching(Self.textContrast, from: accentSource, toward: ink, startingAt: 0, on: reference, isLight: isLight)
        favouriteRGB = Self.reaching(Self.graphicContrast, from: favouriteSource, toward: ink, startingAt: 0, on: reference, isLight: isLight)
    }

    static func contrast(_ a: RGBColor, _ b: RGBColor) -> Double {
        let la = a.relativeLuminance
        let lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func mix(_ a: RGBColor, _ b: RGBColor, _ t: Double) -> RGBColor {
        RGBColor(
            red: a.red * (1 - t) + b.red * t,
            green: a.green * (1 - t) + b.green * t,
            blue: a.blue * (1 - t) + b.blue * t
        )
    }

    /// The first colour on the way from `source` to `ink` that reaches `target`
    /// against `reference` while sitting on the ink's side of it (lighter on dark
    /// themes, darker on Bianco), so it also reads on the darker parts of the screen.
    private static func reaching(
        _ target: Double, from source: RGBColor, toward ink: RGBColor, startingAt start: Double,
        on reference: RGBColor, isLight: Bool
    ) -> RGBColor {
        let referenceLuminance = reference.relativeLuminance
        for step in 0...100 {
            let t = start + (1 - start) * Double(step) / 100
            let candidate = mix(source, ink, t)
            let rightSide = isLight
                ? candidate.relativeLuminance < referenceLuminance
                : candidate.relativeLuminance > referenceLuminance
            if rightSide && contrast(candidate, reference) >= target {
                return candidate
            }
        }
        return ink
    }
}

extension PrismaInk {
    var primary: Color { Self.color(primaryRGB) }
    var secondary: Color { Self.color(secondaryRGB) }
    var accent: Color { Self.color(accentRGB) }
    var accentText: Color { Self.color(accentTextRGB) }
    var favourite: Color { Self.color(favouriteRGB) }
    /// Prototype `.hair`.
    var hairline: Color { isLight ? Self.color(Self.lightInk).opacity(0.10) : Color.white.opacity(0.085) }
    /// Prototype `.fill`: the selected chip and the Riproduci button.
    var fillBackground: Color { isLight ? Self.color(Self.lightInk) : Color.white.opacity(0.95) }
    var fillForeground: Color {
        isLight ? Color.white : Color(red: 18.0 / 255, green: 7.0 / 255, blue: 29.0 / 255)
    }

    private static func color(_ rgb: RGBColor) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

nonisolated struct PrismaInkKey: EnvironmentKey {
    static let defaultValue = PrismaInk.fallback
}

extension EnvironmentValues {
    nonisolated var prismaInk: PrismaInk {
        get { self[PrismaInkKey.self] }
        set { self[PrismaInkKey.self] = newValue }
    }
}

/// Computes the ink once for a whole screen and hands it down, so rows never
/// resolve the theme themselves.
struct PrismaInkProvider: ViewModifier {
    @Environment(ThemeEngine.self) private var theme

    func body(content: Content) -> some View {
        let ink = PrismaInk(resolved: theme.resolved)
        content
            .environment(\.prismaInk, ink)
            .tint(ink.accentText)
    }
}

// MARK: - Transparent lists

extension View {
    func prismaInk() -> some View {
        modifier(PrismaInkProvider())
    }

    /// A plain list whose rows draw nothing behind themselves.
    func prismaList() -> some View {
        listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 44)
    }

    /// A content row with no background of its own: the aura shows through, and
    /// rows are separated by a hairline only.
    func prismaRow() -> some View {
        modifier(PrismaRowStyle())
    }

    /// Glass on a functional element, opaque with Reduce Transparency (spec 5.7).
    func prismaGlass<S: Shape>(_ shape: S) -> some View {
        modifier(PrismaGlass(shape: shape))
    }
}

struct PrismaRowStyle: ViewModifier {
    @Environment(\.prismaInk) private var ink

    func body(content: Content) -> some View {
        content
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(ink.hairline)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
    }
}

struct PrismaGlass<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: shape)
                .glassEffect(.identity, in: shape)
        } else {
            content
                .glassEffect(.regular, in: shape)
        }
    }
}

// MARK: - Shared pieces

/// Prototype `.sect`: a small uppercase label above a group of rows.
struct SectionLabel: View {
    let text: String

    @Environment(\.prismaInk) private var ink

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(ink.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Prototype `.seg`: the selected option filled, the others clear glass. Each
/// option is 34 pt tall but takes touches over 44 pt.
struct FilterChips<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    @Environment(\.prismaInk) private var ink

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(options) { option in
                    let selected = option == selection
                    Button {
                        selection = option
                    } label: {
                        Text(label(option))
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .foregroundStyle(selected ? ink.fillForeground : ink.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 12).fill(ink.fillBackground)
                                }
                            }
                            .modifier(ChipGlass(isSelected: selected))
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

private struct ChipGlass: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content
        } else {
            content.prismaGlass(RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Prototype `.eq`: three bars in the accent colour. Static when paused or with
/// Reduce Motion.
struct EqualizerBars: View {
    let isAnimating: Bool

    @Environment(\.prismaInk) private var ink
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let restingHeights: [Double] = [0.6, 1.0, 0.4]
    private static let phases: [Double] = [0.4, 0, 0.7]

    var body: some View {
        let animating = isAnimating && !reduceMotion
        TimelineView(.animation(minimumInterval: nil, paused: !animating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(ink.accent)
                        .frame(width: 2.5, height: 13 * scale(index, time: time, animating: animating))
                }
            }
            .frame(height: 13, alignment: .bottom)
        }
        .accessibilityElement()
        .accessibilityLabel(isAnimating ? "In riproduzione" : "In pausa")
    }

    /// The prototype's keyframes: scaleY from 0.4 to 1 and back each second.
    private func scale(_ index: Int, time: Double, animating: Bool) -> Double {
        guard animating else { return Self.restingHeights[index] }
        let phase = (time + Self.phases[index]).truncatingRemainder(dividingBy: 1)
        return 0.4 + 0.6 * (0.5 - 0.5 * cos(phase * 2 * .pi))
    }
}

/// Prototype `.ring`: download progress as a ring. nil draws a spinner, for a
/// transfer that has not reported progress yet.
struct ProgressRing: View {
    let fraction: Double?
    let color: Color
    var side: CGFloat = 22

    var body: some View {
        if let fraction {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 2.4)
                Circle()
                    .trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: side, height: side)
            .accessibilityElement()
            .accessibilityLabel("Download al \(Int((fraction * 100).rounded())) percento")
        } else {
            ProgressView()
                .tint(color)
                .frame(width: side, height: side)
                .accessibilityLabel("Download in corso")
        }
    }
}

// MARK: - Italian labels for the primary interface

extension ThemeMode {
    var displayName: String {
        switch self {
        case .adaptive: return "Adattivo"
        case .preset: return "Preset"
        case .monoDark: return "Nero"
        case .monoLight: return "Bianco"
        }
    }
}

extension Formatting {
    /// "3:07", or an empty string when the server sent no duration.
    static func trackTime(_ seconds: Int?) -> String {
        guard let seconds else { return "" }
        return duration(seconds)
    }

    /// "1 brano", "12 brani".
    static func trackCount(_ count: Int) -> String {
        count == 1 ? "1 brano" : "\(count) brani"
    }

    /// "48 min", "1 h 12 min". Tracks without a duration are left out of the sum.
    static func totalDuration(_ seconds: [Int?]) -> String {
        let total = seconds.compactMap { $0 }.reduce(0, +)
        let minutes = total == 0 ? 0 : max(1, Int((Double(total) / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min"
        }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "12 brani · 48 min".
    static func trackSummary(_ tracks: [TrackRowData]) -> String {
        trackCount(tracks.count) + " · " + totalDuration(tracks.map(\.durationS))
    }
}
