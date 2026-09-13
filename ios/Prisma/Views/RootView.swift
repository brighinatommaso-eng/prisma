import SwiftData
import SwiftUI

struct RootView: View {
    let model: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var showingPlayer = false

    var body: some View {
        if let services = model.services {
            TabView {
                Tab("Settings", systemImage: "gear") {
                    withMiniPlayer(NavigationStack { SettingsView() })
                }
                Tab("Search", systemImage: "magnifyingglass") {
                    withMiniPlayer(NavigationStack { SearchView() })
                }
                Tab("Library", systemImage: "square.stack") {
                    withMiniPlayer(NavigationStack { LibraryView() })
                }
                Tab("Downloads", systemImage: "arrow.down.circle") {
                    withMiniPlayer(NavigationStack { DownloadsView() })
                }
            }
            .fullScreenCover(isPresented: $showingPlayer) {
                FullPlayerView()
                    .environment(model.settings)
                    .environment(services.downloads)
                    .environment(services.playback)
                    .modelContainer(services.container)
            }
            .environment(services.downloads)
            .environment(services.sync)
            .environment(services.playback)
            .modelContainer(services.container)
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    services.downloads.checkTransfers(reason: "app opened")
                case .background:
                    services.playback.persist()
                default:
                    break
                }
            }
        } else {
            NavigationStack {
                List {
                    if let error = model.launchError {
                        ErrorReport(error: error)
                    } else {
                        Text("The app services were not created, and no error was recorded.")
                    }
                }
                .navigationTitle("Prisma cannot start")
            }
        }
    }

    /// The mini-player sits above the tab bar, on every tab.
    private func withMiniPlayer<Content: View>(_ content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView {
                showingPlayer = true
            }
        }
    }
}
