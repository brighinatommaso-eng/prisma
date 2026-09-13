import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Create the background session now, even when iOS launched the app only
        // to deliver finished downloads and no view will be shown.
        _ = AppModel.shared
        return true
    }

    /// Without this, transfers that finish while the app is suspended or not
    /// running are never reported: iOS waits for the completion handler.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard let downloads = AppModel.shared.services?.downloads else {
            // The database failed to open; the app shows that error when opened.
            completionHandler()
            return
        }
        downloads.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
    }
}
