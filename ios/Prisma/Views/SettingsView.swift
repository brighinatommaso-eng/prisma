import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ThemeEngine.self) private var theme
    @Environment(ServerReachability.self) private var reachability
    @Environment(\.prismaInk) private var ink

    @State private var draft = ""
    @State private var draftLoaded = false
    @State private var saveResult: SaveResult?
    @State private var test: LoadState<APIResponse<Health>> = .idle
    @State private var testGeneration = 0

    private let buildInfo = BuildInfo(bundle: .main)

    /// The recorded reachability answer, short enough for a value row. The whole
    /// sentence, with the reason, is `ServerReachability.statusLine`, which
    /// Preferiti shows when it changes what the user can do.
    private var reachabilityValue: String {
        if reachability.isProbing, reachability.isReachable == nil {
            return "Controllo in corso…"
        }
        let when = reachability.checkedAt.map { " · " + Formatting.time($0) } ?? ""
        switch reachability.isReachable {
        case nil: return "Non ancora controllato"
        case true?: return "Disponibile" + when
        case false?: return "Non disponibile" + when
        }
    }

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
                if theme.mode == .adaptive {
                    Text("Adattivo segue i colori dell'album in riproduzione; senza musica usa il preset Prisma.")
                        .font(.caption)
                        .foregroundStyle(ink.secondary)
                        .padding(.top, 6)
                }
                if let problem = theme.settingsProblem {
                    ProblemBlock(problem)
                        .padding(.top, 6)
                }

                SectionLabel("Info")
                infoCard

                NavigationLink {
                    ThemeInspectorView()
                } label: {
                    HStack {
                        Text("Ispettore del tema (strumento di sviluppo)")
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
                TextField("http://nome-server:8000", text: $draft)
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

            valueRow("Stato") {
                statusValue
            }

            hairline

            // What the rest of the app is acting on: the recorded answer that
            // decides whether a track only the server has can be streamed.
            valueRow("Streaming") {
                Text(reachabilityValue)
                    .foregroundStyle(ink.secondary)
                    .multilineTextAlignment(.trailing)
            }

            if case .loaded(let response) = test {
                let health = response.value
                hairline
                valueRow("YouTube Music") {
                    Text(health.youtubeMusicReachable ? "Raggiungibile" : "Non raggiungibile")
                        .foregroundStyle(health.youtubeMusicReachable ? ink.secondary : ink.primary)
                }
                hairline
                valueRow("Catalogo") {
                    Text("\(Formatting.trackCount(health.trackCount)), \(health.albumCount == 1 ? "1 album" : "\(health.albumCount) album")")
                        .foregroundStyle(ink.secondary)
                }
                hairline
                valueRow("Spazio libero sul server") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(health.musicFreeBytes), countStyle: .file))
                        .foregroundStyle(ink.secondary)
                }
                hairline
                valueRow("yt-dlp") {
                    Text(health.ytdlpVersion)
                        .foregroundStyle(ink.secondary)
                }
            }

            hairline

            HStack(spacing: 0) {
                cardButton("Salva") { save() }
                Rectangle()
                    .fill(ink.hairline)
                    .frame(width: 0.5)
                cardButton("Verifica connessione") { testConnection() }
            }
            .frame(minHeight: 50)

            messages
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
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

    /// Save confirmation and failures, each a complete sentence.
    @ViewBuilder
    private var messages: some View {
        switch saveResult {
        case .saved(_)?:
            Text("Indirizzo salvato su questo telefono.")
                .font(.caption)
                .foregroundStyle(ink.secondary)
                .padding(.top, 4)
        case .failed(let error)?:
            ProblemBlock("L'indirizzo non è stato salvato. " + PlainLanguage.message(for: error))
        case nil:
            EmptyView()
        }
        if case .failed(let error) = test, !saveFailed {
            ProblemBlock("La verifica della connessione non è riuscita. " + PlainLanguage.message(for: error))
        }
        if case .loaded(let response) = test, !response.value.youtubeMusicReachable {
            ProblemBlock("Il server è raggiungibile, ma non raggiunge YouTube Music: ricerche e nuovi download non riusciranno finché la sua connessione a internet non torna.")
        }
    }

    private var saveFailed: Bool {
        if case .failed(_)? = saveResult {
            return true
        }
        return false
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
            valueRow("Versione") {
                Text("\(buildInfo.version) (build \(buildInfo.build))")
                    .foregroundStyle(ink.secondary)
                    .textSelection(.enabled)
            }
            hairline
            valueRow("Revisione") {
                Text(Self.localised(buildInfo.commit))
                    .foregroundStyle(ink.secondary)
                    .textSelection(.enabled)
            }
        }
        .prismaGlass(RoundedRectangle(cornerRadius: 20))
    }

    /// BuildInfo's placeholders, in Italian.
    private static func localised(_ value: String) -> String {
        switch value {
        case "unknown": return "sconosciuta"
        case "local": return "build locale"
        default: return value
        }
    }

    // MARK: - Pieces

    private func valueRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(ink.primary)
            Spacer(minLength: 0)
            value()
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }

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
            test = .failed(.invalidInput("Connessione non verificata", detail: "Prima correggi l'indirizzo."))
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
        // The same tap answers the question the rest of the app asks, so a user who
        // has just brought the server back does not have to wait for another event
        // before a streamed track becomes playable.
        reachability.retry()
    }
}
