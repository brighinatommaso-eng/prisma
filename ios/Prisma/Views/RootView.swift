import SwiftData
import SwiftUI

struct RootView: View {
    let model: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var presenter = PlayerPresenter()

    var body: some View {
        if let services = model.services {
            let colorScheme = services.theme.resolved.surface.colorScheme
            TabView {
                Tab("Settings", systemImage: "gear") {
                    NavigationStack { tabRoot(SettingsView()) }
                }
                Tab("Search", systemImage: "magnifyingglass") {
                    NavigationStack { tabRoot(SearchView()) }
                }
                Tab("Library", systemImage: "square.stack") {
                    NavigationStack { tabRoot(LibraryView()) }
                }
                Tab("Downloads", systemImage: "arrow.down.circle") {
                    NavigationStack { tabRoot(DownloadsView()) }
                }
            }
            .fullScreenCover(isPresented: $presenter.isPresented) {
                FullPlayerView()
                    .environment(model.settings)
                    .environment(services.downloads)
                    .environment(services.playback)
                    .environment(services.theme)
                    .environment(services.playlists)
                    .modelContainer(services.container)
                    .preferredColorScheme(colorScheme)
            }
            .environment(services.downloads)
            .environment(services.sync)
            .environment(services.playback)
            .environment(services.theme)
            .environment(services.playlists)
            .environment(presenter)
            .modelContainer(services.container)
            // Spec 5.5: the theme's polarity reaches the system tab bar and every
            // glass surface through the colour scheme, not through repainted materials.
            .preferredColorScheme(colorScheme)
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

    /// A tab's root screen: the theme background behind it, and the mini-player
    /// above the tab bar.
    ///
    /// The mini-player shrinks the safe area of the screen beneath it so the last row
    /// of a list scrolls clear of it. Applied inside each NavigationStack: outside,
    /// the inset stops at the navigation stack (a UIKit container) and never reaches
    /// the List, which is how build 8 drew the bar over the last row. When nothing
    /// is loaded MiniPlayerView renders no view, so the inset is zero.
    private func tabRoot<Content: View>(_ content: Content) -> some View {
        content
            .miniPlayerInset()
            .themedScreenBackground()
    }
}
