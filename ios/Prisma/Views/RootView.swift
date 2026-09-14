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
                    NavigationStack { withMiniPlayer(SettingsView()) }
                }
                Tab("Search", systemImage: "magnifyingglass") {
                    NavigationStack { withMiniPlayer(SearchView()) }
                }
                Tab("Library", systemImage: "square.stack") {
                    NavigationStack { withMiniPlayer(LibraryView()) }
                }
                Tab("Downloads", systemImage: "arrow.down.circle") {
                    NavigationStack { withMiniPlayer(DownloadsView()) }
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

    /// The mini-player sits above the tab bar, on every tab, and shrinks the safe
    /// area of the screen beneath it so the last row of a list scrolls clear of it.
    ///
    /// Applied to each tab's root screen, inside its NavigationStack. Applied
    /// outside, the inset stops at the navigation stack (a UIKit container) and
    /// never reaches the List, which is how build 8 drew the bar over the last row.
    /// When nothing is loaded MiniPlayerView renders no view, so the inset is zero.
    private func withMiniPlayer<Content: View>(_ content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerView {
                showingPlayer = true
            }
        }
    }
}
