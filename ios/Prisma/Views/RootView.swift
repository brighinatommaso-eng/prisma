import SwiftData
import SwiftUI

struct RootView: View {
    let model: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var presenter = PlayerPresenter()

    var body: some View {
        if let services = model.services {
            let colorScheme = services.theme.resolved.surface.colorScheme
            // Prototype tab bar order: Libreria, Cerca, Download, Impostazioni.
            TabView {
                Tab("Libreria", systemImage: "books.vertical") {
                    NavigationStack { tabRoot(LibraryView()) }
                        .prismaInk()
                }
                Tab("Cerca", systemImage: "magnifyingglass") {
                    NavigationStack { tabRoot(SearchView()) }
                        .prismaInk()
                }
                Tab("Download", systemImage: "arrow.down.circle") {
                    NavigationStack { tabRoot(DownloadsView()) }
                        .prismaInk()
                }
                Tab("Impostazioni", systemImage: "gearshape") {
                    NavigationStack { tabRoot(SettingsView()) }
                        .prismaInk()
                }
            }
            .fullScreenCover(isPresented: $presenter.isPresented) {
                // The ink provider reads the theme, so it sits inside the
                // environment modifiers that supply it.
                FullPlayerView()
                    .prismaInk()
                    .environment(model.settings)
                    .environment(services.downloads)
                    .environment(services.playback)
                    .environment(services.theme)
                    .environment(services.playlists)
                    .environment(services.deletion)
                    .environment(presenter)
                    .modelContainer(services.container)
                    .preferredColorScheme(colorScheme)
            }
            .environment(services.downloads)
            .environment(services.sync)
            .environment(services.playback)
            .environment(services.theme)
            .environment(services.playlists)
            .environment(services.acquisitions)
            .environment(services.deletion)
            .environment(presenter)
            .modelContainer(services.container)
            // Spec 5.5: the theme's polarity reaches the system tab bar and every
            // glass surface through the colour scheme, not through repainted materials.
            .preferredColorScheme(colorScheme)
            // onChange does not fire for the scene phase at launch: continue any
            // acquisition left unfinished by the last run.
            .task {
                services.acquisitions.resume()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    services.downloads.checkTransfers(reason: "apertura dell'app")
                    services.acquisitions.resume()
                case .background:
                    services.playback.persist()
                    services.acquisitions.pause()
                default:
                    break
                }
            }
        } else {
            NavigationStack {
                List {
                    Text("La libreria sul telefono non si è aperta, quindi l'app non può partire: riavvia l'app; se si ripete, libera spazio sul telefono o reinstalla l'app.")
                }
                .navigationTitle("Prisma non si avvia")
            }
        }
    }

    /// A tab's root screen: the theme background behind it, and the mini-player
    /// above the tab bar. The ink is applied outside the NavigationStack, so screens
    /// pushed inside the tab get it too.
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
