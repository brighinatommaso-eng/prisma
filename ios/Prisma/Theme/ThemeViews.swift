import SwiftUI

extension RGBColor {
    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

/// The screen background for the current theme: flat colour, aura and scrim.
/// Sits behind content and never takes touches.
struct ThemeBackground: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let resolved = theme.resolved
        ZStack {
            resolved.surface.background.color
            if resolved.surface.showsAura {
                AuraView(palette: resolved.palette)
                    .transition(.opacity)
            }
            if let top = resolved.surface.scrimTop, let bottom = resolved.surface.scrimBottom {
                LinearGradient(
                    colors: [
                        ThemeCatalog.auraBackground.color.opacity(top),
                        ThemeCatalog.auraBackground.color.opacity(bottom),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // Spec 5.7: with Reduce Motion the aura changes at once instead of morphing.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: resolved)
    }
}

/// Four blurred ellipses, laid out as the prototype's `.aura` (inset -32%, blur 74).
struct AuraView: View {
    let palette: AuraPalette

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * 1.64
            let height = proxy.size.height * 1.64
            ZStack(alignment: .topLeading) {
                blob(0, width: width, height: height, x: -0.08, y: 0.00, w: 0.64, h: 0.44)
                blob(1, width: width, height: height, x: 0.52, y: 0.15, w: 0.58, h: 0.40)
                blob(2, width: width, height: height, x: 0.00, y: 0.38, w: 0.70, h: 0.46)
                blob(3, width: width, height: height, x: 0.44, y: 0.58, w: 0.62, h: 0.42)
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .blur(radius: 74)
            .offset(x: -proxy.size.width * 0.32, y: -proxy.size.height * 0.32)
        }
    }

    private func blob(_ index: Int, width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        Ellipse()
            .fill(palette.colors[index].color)
            .frame(width: width * w, height: height * h)
            .offset(x: width * x, y: height * y)
    }
}

/// System glass for a functional-layer surface (spec 5.1), following the theme's
/// colour scheme for its polarity. With Reduce Transparency it becomes opaque
/// (spec 5.7).
struct GlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background)
                .glassEffect(.identity, in: Rectangle())
        } else {
            content
                .glassEffect(.regular, in: Rectangle())
        }
    }
}

extension View {
    func glassSurface() -> some View {
        modifier(GlassSurface())
    }

    /// Lets the theme background show through a List or Form. Rows keep their
    /// own opaque backgrounds: content stays on solid surfaces (spec 5.1).
    func themedScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background {
                ThemeBackground()
            }
    }
}
