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
                Text("Strumento di sviluppo, temporaneo: serve solo a controllare il motore dei temi su questo telefono e verrà rimosso.")
                    .font(.headline)
            }

            Section {
                FieldRow(label: "Modalità", value: resolved.mode.label)
                FieldRow(label: "Origine della palette", value: resolved.source)
                if let problem = resolved.problem {
                    FieldRow(label: "Problema", value: problem)
                }
                if let settingsProblem = theme.settingsProblem {
                    FieldRow(label: "Problema nelle impostazioni salvate", value: settingsProblem)
                }
                if theme.testPalette != nil {
                    Button("Ferma la palette di prova (torna al brano in riproduzione)") {
                        theme.clearTestPalette()
                    }
                }
                FieldRow(label: "Sfondo", value: resolved.surface.background.hex)
                FieldRow(label: "Schema colori (polarità del vetro)", value: resolved.surface.colorScheme == .light ? "chiaro" : "scuro")
                FieldRow(label: "Aura", value: resolved.surface.showsAura ? "attiva" : "assente (tema piatto)")
            } header: {
                Text("Tema attivo").textCase(nil)
            }

            Section {
                ForEach(Array(resolved.palette.colors.enumerated()), id: \.offset) { index, color in
                    SwatchRow(
                        index: index,
                        color: color,
                        incoming: resolved.incoming?.colors[index],
                        clamped: resolved.clamped?.colors[index]
                    )
                }
            } header: {
                Text(resolved.surface.showsAura ? "Colori attivi" : "Colori (non disegnati in questa modalità)").textCase(nil)
            }

            Section {
                FieldRow(label: "Luminanza relativa media", value: String(format: "%.3f", resolved.luminance))
                if let base = resolved.surface.scrimBase,
                   let top = resolved.surface.scrimTop,
                   let bottom = resolved.surface.scrimBottom {
                    FieldRow(label: "Base del velo (calcolata)", value: String(format: "%.2f", base))
                    FieldRow(label: "Velo disegnato", value: String(format: "in alto %.2f, in basso %.2f (massimo %.2f)", top, bottom, ThemeResolver.scrimCeiling))
                    CompositeRow(label: "Colore più chiaro sotto il velo, in alto", source: resolved.palette.brightest, opacity: top)
                    CompositeRow(label: "Colore più chiaro sotto il velo, in basso", source: resolved.palette.brightest, opacity: bottom)
                } else {
                    FieldRow(label: "Velo", value: "nessuno in modalità \(resolved.mode.label)")
                }
                Text(String(
                    format: "La base vale %.2f con luminanza ≤ %.2f e %.2f con luminanza ≥ %.2f, lineare nel mezzo. Il velo va da base − %.2f in alto a base + %.2f in basso, mai oltre %.2f. I colori dal server sono limitati a luminosità HLS %.2f, poi la saturazione sale del %.0f%% verso il massimo; i preset si usano così come sono.",
                    ThemeResolver.scrimMinimum, ThemeResolver.luminanceAtMinimum,
                    ThemeResolver.scrimCeiling, ThemeResolver.luminanceAtMaximum,
                    ThemeResolver.scrimSpread, ThemeResolver.scrimSpread, ThemeResolver.scrimCeiling,
                    ThemeResolver.maxLightness, ThemeResolver.saturationBoost * 100
                ))
                .font(.caption)
            } header: {
                Text("Contrasto").textCase(nil)
            }

            Section {
                FieldRow(label: "Riduci trasparenza", value: reduceTransparency ? "attivo: le superfici di vetro sono opache" : "disattivo")
                FieldRow(label: "Riduci movimento", value: reduceMotion ? "attivo: i cambi di palette sono istantanei" : "disattivo")
            } header: {
                Text("Accessibilità").textCase(nil)
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
                Text("Modalità").textCase(nil)
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
                Text("Preset (specifica 5.3)").textCase(nil)
            } footer: {
                Text("Toccare un preset attiva anche la modalità Preset.")
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
                Text("Palette di prova").textCase(nil)
            } footer: {
                Text("Applicate come se il server le avesse inviate per l'album in riproduzione: modalità Adattivo, limite di luminosità compreso. Non vengono salvate e spariscono al riavvio.")
            }
        }
        .navigationTitle("Ispettore del tema")
        // Pushed inside a tab, so it needs the mini player inset itself.
        .miniPlayerInset()
        .themedScreenBackground()
    }
}

/// A source colour composited with the scrim at one opacity: what is actually on
/// screen there, and how readable white text is on it.
private struct CompositeRow: View {
    let label: String
    let source: RGBColor
    let opacity: Double

    var body: some View {
        let result = ThemeResolver.composite(source, scrimOpacity: opacity)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(result.color)
                .frame(width: 48, height: 48)
                .overlay(
                    Text("Aa")
                        .font(.headline)
                        .foregroundStyle(.white)
                )
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                Text(String(format: "%@ sotto %@ al %.2f → %@", source.hex, ThemeResolver.scrimColor.hex, opacity, result.hex))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text(String(format: "contrasto del testo bianco %.1f:1", ThemeResolver.whiteTextContrast(on: result)))
                    .font(.caption.monospaced())
            }
        }
    }
}

private struct SwatchRow: View {
    let index: Int
    let color: RGBColor
    let incoming: RGBColor?
    let clamped: RGBColor?

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
                Text(String(format: "luminanza %.3f, luminosità %.2f", color.relativeLuminance, color.lightness))
                    .font(.caption.monospaced())
                if let incoming, let clamped, incoming != color {
                    Text("ricevuto \(incoming.hex) → limitato \(clamped.hex) → saturato \(color.hex)")
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
