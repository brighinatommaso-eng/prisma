import SwiftUI

@main
struct PrismaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .environment(model.settings)
        }
    }
}
