import Foundation
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ThemeEngine.self) private var theme

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
        Form {
            Section {
                TextField("http://hostname:8000", text: $draft)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { save() }
                Button("Save") { save() }
                Button("Test connection") { testConnection() }
                FieldRow(
                    label: "Saved address",
                    value: settings.savedAddress.isEmpty ? "(none)" : settings.savedAddress
                )
                switch saveResult {
                case .saved(let address)?:
                    Text("Saved \(address)")
                case .failed(let error)?:
                    ErrorReport(error: error)
                case nil:
                    EmptyView()
                }
            } header: {
                Text("Server").textCase(nil)
            } footer: {
                Text("Stored on this iPhone only. Include http:// and the port. Test connection saves the address first.")
            }

            Section {
                testContent
            } header: {
                Text("Connection test").textCase(nil)
            }

            if case .loaded(let response) = test {
                Section {
                    Text(response.bodyText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } header: {
                    Text("Raw /health response").textCase(nil)
                }
            }

            Section {
                Picker("Mode", selection: Binding(
                    get: { theme.mode },
                    set: { theme.setMode($0) }
                )) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if theme.mode == .preset {
                    Picker("Preset", selection: Binding(
                        get: { theme.presetID },
                        set: { theme.setPreset(id: $0) }
                    )) {
                        ForEach(ThemeCatalog.presets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
                NavigationLink("Theme inspector (development tool)") {
                    ThemeInspectorView()
                }
            } header: {
                Text("Appearance").textCase(nil)
            } footer: {
                Text("Adaptive follows the colours of the playing album and uses the Prisma preset when nothing is playing.")
            }

            Section {
                FieldRow(label: "Version", value: buildInfo.version)
                FieldRow(label: "Build", value: buildInfo.build)
                FieldRow(label: "Commit", value: buildInfo.commit)
            } header: {
                Text("This build").textCase(nil)
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            if !draftLoaded {
                draft = settings.savedAddress
                draftLoaded = true
            }
        }
    }

    @ViewBuilder
    private var testContent: some View {
        switch test {
        case .idle:
            Text("Not tested yet.")
        case .loading(let since):
            LoadingRow(message: "Calling /health…", since: since, timeout: APIClient.Timeout.health)
        case .failed(let error):
            ErrorReport(error: error)
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
        }
    }

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
