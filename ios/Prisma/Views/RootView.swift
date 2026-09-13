import SwiftData
import SwiftUI

struct RootView: View {
    let model: AppModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let services = model.services {
            TabView {
                Tab("Settings", systemImage: "gear") {
                    NavigationStack { SettingsView() }
                }
                Tab("Search", systemImage: "magnifyingglass") {
                    NavigationStack { SearchView() }
                }
                Tab("Library", systemImage: "square.stack") {
                    NavigationStack { LibraryView() }
                }
                Tab("Downloads", systemImage: "arrow.down.circle") {
                    NavigationStack { DownloadsView() }
                }
            }
            .environment(services.downloads)
            .environment(services.sync)
            .modelContainer(services.container)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    services.downloads.checkTransfers(reason: "app opened")
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
}
