import SwiftUI

/// DEVELOPMENT TOOL. Temporary: makes the theme engine checkable on the phone, where
/// there is no debugger. Remove it once the design phase is verified.
struct ThemeInspectorView: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let resolved = theme.resolved
        List {
            Section {
                Text("Development tool. Temporary: it exists only to check the theme engine on this iPhone and will be removed.")
                    .font(.headline)
            }

            Section {
                FieldRow(label: "Mode", value: resolved.mode.label)
                FieldRow(label: "Palette source", value: resolved.source)
                if let problem = resolved.problem {
                    FieldRow(label: "Problem", value: problem)
                }
                if let settingsProblem = theme.settingsProblem {
                    FieldRow(label: "Saved settings problem", value: settingsProblem)
                }
                if theme.testPalette != nil {
                    Button("Stop test palette (back to the playing track)") {
                        theme.clearTestPalette()
                    }
                }
                FieldRow(label: "Background", value: resolved.surface.background.hex)
                FieldRow(label: "Colour scheme (glass polarity)", value: resolved.surface.colorScheme == .light ? "light" : "dark")
                FieldRow(label: "Aura", value: resolved.surface.showsAura ? "on" : "off (flat theme)")
            } header: {
                Text("Active theme").textCase(nil)
            }

            Section {
                ForEach(Array(resolved.palette.colors.enumerated()), id: \.offset) { index, color in
                    SwatchRow(
                        index: index,
                        color: color,
                        incoming: resolved.incoming?.colors[index]
                    )
                }
            } header: {
                Text(resolved.surface.showsAura ? "Active colours" : "Colours (not drawn in this mode)").textCase(nil)
            }

            Section {
                FieldRow(label: "Mean relative luminance", value: String(format: "%.3f", resolved.luminance))
                if let top = resolved.surface.scrimTop, let bottom = resolved.surface.scrimBottom {
                    FieldRow(label: "Scrim opacity", value: String(format: "%.2f (top), %.2f (bottom)", top, bottom))
                } else {
                    FieldRow(label: "Scrim opacity", value: "none: no scrim in \(resolved.mode.label)")
                }
                Text(String(
                    format: "Scrim is %.2f at luminance ≤ %.2f and %.2f at ≥ %.2f, linear in between. Colours from the server are clamped to HLS lightness %.2f; presets are not.",
                    ThemeResolver.scrimMinimum, ThemeResolver.luminanceAtMinimum,
                    ThemeResolver.scrimMaximum, ThemeResolver.luminanceAtMaximum,
                    ThemeResolver.maxLightness
                ))
                .font(.caption)
            } header: {
                Text("Contrast").textCase(nil)
            }

            Section {
                FieldRow(label: "Reduce Transparency", value: reduceTransparency ? "on: glass surfaces are opaque" : "off")
                FieldRow(label: "Reduce Motion", value: reduceMotion ? "on: palette changes are instant" : "off")
            } header: {
                Text("Accessibility").textCase(nil)
            }

            Section {
                ForEach(ThemeMode.allCases) { mode in
                    Button {
                        theme.setMode(mode)
                    } label: {
                        CheckRow(title: mode.label, isSelected: theme.mode == mode)
                    }
                }
            } header: {
                Text("Mode").textCase(nil)
            }

            Section {
                ForEach(ThemeCatalog.presets) { preset in
                    Button {
                        theme.setPreset(id: preset.id)
                        theme.setMode(.preset)
                    } label: {
                        PaletteRow(palette: preset, isSelected: theme.mode == .preset && theme.presetID == preset.id)
                    }
                }
            } header: {
                Text("Presets (spec 5.3)").textCase(nil)
            } footer: {
                Text("Tapping a preset also switches to Preset mode.")
            }

            Section {
                ForEach(ThemeCatalog.testPalettes) { palette in
                    Button {
                        theme.applyTestPalette(palette)
                    } label: {
                        PaletteRow(palette: palette, isSelected: theme.testPalette?.id == palette.id)
                    }
                }
            } header: {
                Text("Synthetic test palettes").textCase(nil)
            } footer: {
                Text("Applied as if the server had sent them for the playing album: Adaptive mode, lightness clamp included. Not saved; cleared on restart.")
            }
        }
        .navigationTitle("Theme inspector")
        .themedScreenBackground()
    }
}

private struct SwatchRow: View {
    let index: Int
    let color: RGBColor
    let incoming: RGBColor?

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color.color)
                .frame(width: 48, height: 48)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("c\(index + 1)  \(color.hex)")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(String(format: "luminance %.3f, lightness %.2f", color.relativeLuminance, color.lightness))
                    .font(.caption.monospaced())
                if let incoming, incoming != color {
                    Text("received \(incoming.hex) (lightness \(String(format: "%.2f", incoming.lightness))), clamped")
                        .font(.caption.monospaced())
                }
            }
        }
    }
}

private struct PaletteRow: View {
    let palette: NamedPalette
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    ForEach(Array(palette.hexes.enumerated()), id: \.offset) { _, hex in
                        Rectangle()
                            .fill(RGBColor(hex: hex)?.color ?? Color.clear)
                            .frame(width: 18, height: 28)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.secondary, lineWidth: 1))
                CheckRow(title: palette.name, isSelected: isSelected)
            }
            Text(palette.hexes.joined(separator: " "))
                .font(.caption2.monospaced())
            if !palette.purpose.isEmpty {
                Text(palette.purpose)
                    .font(.caption2)
            }
        }
    }
}

private struct CheckRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
        .contentShape(Rectangle())
    }
}
