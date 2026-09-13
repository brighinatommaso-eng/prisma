import SwiftUI

struct RootView: View {
    var body: some View {
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
        }
    }
}
