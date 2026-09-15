import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.prismaInk) private var ink

    @State private var draft = ""
    @State private var draftLoaded = false
    @State private var saveResult: SaveResult?
    @State private var test: LoadState<APIResponse<Health>> = .idle
    @State private var testGeneration = 0

    private let buildInfo = BuildInfo(bundle: .main)

    private enum SaveResult {
        case saved(String)
        case failed(APIError)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Server")
                serverCard

                SectionLabel("Aspetto")
                FilterChips(options: ThemeMode.allCases, selection: Binding(
                    get: { theme.mode },
                    set: { theme.setMode($0) }
                )) { $0.displayName }
                if theme.mode == .preset {
                    presetGrid
                        .padding(.top, 8)
                }
                Text(theme.mode == .adaptive
                     ? "Adattivo segue i colori dell'album in riproduzione; senza musica usa il preset Prisma."
                     : " ")
                    .font(.caption)
                    .foregroundStyle(ink.secondary)
                    .padding(.top, 6)

                SectionLabel("Info")
                infoCard

                NavigationLink {
                    ThemeInspectorView()
                } label: {
                    HStack {
                        Text("Theme inspector (strumento di sviluppo)")
                            .font(.subheadline)
                            .foregroundStyle(ink.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(ink.secondary)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .prismaGlass(RoundedRectangle(cornerRadius: 20))
                .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Impostazioni")
        .onAppear {
            if !draftLoaded {
                draft = settings.savedAddress
                draftLoaded = true
            }
        }
    }

    // MARK: - Server

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Indirizzo")
                    .foregroundStyle(ink.primary)
                TextField("http://hostname:8000", text: $draft)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(ink.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)

            hairline

            HStack(spacing: 12) {
                Text("Stato")
                    .foregroundStyle(ink.primary)
                Spacer(minLength: 0)
                statusValue
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)

            hairline

            HStack(spacing: 0) {
                cardButton("Salva") { save() }
                Rectangle()
                    .fill(ink.hairline)
                    .frame(width: 0.5)
                cardButton("Verifica connessione") { testConnection() }
            }
            .frame(minHeight: 50)

            problems
                .padding(.horizontal, 16)

            TechnicalDetailsSection {
                serverDetails
            }
            .padding(.horizontal, 16)
        }
        .prismaGlass(RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var statusValue: some View {
        switch test {
        case .idle:
            Text(settings.savedAddress.isEmpty ? "Nessun indirizzo" : "Non verificato")
                .foregroundStyle(ink.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .tint(ink.secondary)
                Text("Verifica…")
                    .foregroundStyle(ink.secondary)
            }
        case .failed:
            Text("Non raggiungibile")
                .foregroundStyle(ink.primary)
        case .loaded:
            Text("Connesso")
                .fontWeight(.semibold)
                .foregroundStyle(ink.accentText)
        }
    }

    /// Failures in plain language; the full report is behind the toggle.
    @ViewBuilder
    private var problems: some View {
        if case .failed(let error)? = saveResult {
            ProblemBlock(summary: "Indirizzo non salvato: " + PlainLanguage.summary(for: error).lowercasedFirst,
                         details: .error(error))
        } else if case .failed(let error) = test {
            ProblemBlock(summary: "Verifica non riuscita: " + PlainLanguage.summary(for: error).lowercasedFirst,
                         details: .error(error))
        }
    }

    @ViewBuilder
    private var serverDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldRow(label: "Saved address", value: settings.savedAddress.isEmpty ? "(none)" : settings.savedAddress)
            if case .saved(let address)? = saveResult {
                Text("Saved \(address)")
            }
            Text("Stored on this iPhone only. Include http:// and the port. Test connection saves the address first.")
            switch test {
            case .idle:
                Text("Not tested yet.")
            case .loading(let since):
                LoadingRow(message: "Calling /health…", since: since, timeout: APIClient.Timeout.health)
            case .failed(let error):
                Text(error.fullText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            case .loaded(let response):
                let health = response.value
                FieldRow(label: "Result", value: "Connected: HTTP \(response.status) in \(response.milliseconds) ms")
                FieldRow(label: "URL", value: response.url.absoluteString)
                FieldRow(label: "Received at", value: response.receivedAt.formatted(date: .omitted, time: .standard))
                FieldRow(label: "track_count", value: String(health.trackCount))
                FieldRow(label: "album_count", value: String(health.albumCount))
                FieldRow(label: "total_bytes_stored", value: Formatting.bytes(health.totalBytesStored))
                FieldRow(label: "music_free_bytes", value: Formatting.bytes(health.musicFreeBytes))
                FieldRow(label: "youtube_music_reachable", value: health.youtubeMusicReachable ? "true" : "false")
                FieldRow(label: "ytdlp_version", value: health.ytdlpVersion)
                FieldRow(label: "ytmusicapi_version", value: health.ytmusicapiVersion)
                Text("Raw /health response")
                    .font(.caption.weight(.semibold))
                Text(response.bodyText)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Appearance

    /// Prototype `.presets`: three columns of swatches, the selected one outlined.
    private var presetGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3), spacing: 9) {
            ForEach(ThemeCatalog.presets) { preset in
                let selected = theme.presetID == preset.id
                Button {
                    theme.setPreset(id: preset.id)
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 0) {
                            ForEach(Array(preset.hexes.enumerated()), id: \.offset) { _, hex in
                                let rgb = RGBColor(hex: hex) ?? ThemeCatalog.auraBackground
                                Rectangle()
                                    .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                            }
                        }
                        .frame(height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(preset.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ink.primary)
                            .lineLimit(1)
                    }
                    .padding(8)
                    .frame(minHeight: 44)
                    .prismaGlass(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: 15)
                                .stroke(ink.primary, lineWidth: 2)
                                .padding(-1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preset \(preset.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: - Info

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Versione")
                    .foregroundStyle(ink.primary)
                Spacer(minLength: 0)
                Text("\(buildInfo.version) (\(buildInfo.build))")
                    .foregroundStyle(ink.secondary)
                    .textSelection(.enabled)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(minHeight: 50)

            TechnicalDetailsSection {
                VStack(alignment: .leading, spacing: 8) {
                    FieldRow(label: "Version", value: buildInfo.version)
                    FieldRow(label: "Build", value: buildInfo.build)
                    FieldRow(label: "Commit", value: buildInfo.commit)
                    if let problem = theme.settingsProblem {
                        FieldRow(label: "Theme settings problem", value: problem)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .prismaGlass(RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Pieces

    private var hairline: some View {
        Rectangle()
            .fill(ink.hairline)
            .frame(height: 0.5)
    }

    private func cardButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink.accentText)
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    @discardableResult
    private func save() -> ServerAddress? {
        do {
            let address = try settings.save(draft)
            draft = address.url.absoluteString
            saveResult = .saved(address.url.absoluteString)
            return address
        } catch {
            saveResult = .failed(.from(error))
            return nil
        }
    }

    private func testConnection() {
        testGeneration += 1
        let current = testGeneration

        guard let address = save() else {
            // save() has already put the reason on screen, above.
            test = .failed(.invalidInput("Not tested", detail: "The address could not be saved; see the error in the Server section."))
            return
        }

        test = .loading(since: Date())
        let client = APIClient(address: address)
        Task {
            let outcome: LoadState<APIResponse<Health>>
            do {
                outcome = .loaded(try await client.health())
            } catch {
                outcome = .failed(.from(error))
            }
            // A newer tap owns the result.
            guard current == testGeneration else { return }
            test = outcome
        }
    }
}
