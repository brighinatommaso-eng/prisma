import AVFoundation
import CoreMedia
import Foundation
import MediaPlayer
import UIKit

/// Creates every callback that AVFoundation, MediaPlayer and NotificationCenter
/// invoke, and hands each one to the main actor explicitly.
///
/// The closures are formed here, in nonisolated code, on purpose. A closure
/// written inside `PlaybackEngine` would inherit its main-actor isolation, and
/// several of these frameworks call their handlers on background threads, which
/// traps at runtime. That failure only shows on a device, as a crash with nothing
/// on screen, so the hop to the main actor is done in one place, deliberately.
nonisolated enum PlaybackBridge {
    /// Key-value observation of the player. Runs `handler` on the main actor,
    /// synchronously when the change already happened on the main thread.
    static func observe<Value>(
        _ player: AVQueuePlayer,
        _ keyPath: KeyPath<AVQueuePlayer, Value>,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> NSKeyValueObservation {
        player.observe(keyPath, options: [.new]) { _, _ in
            onMain(handler)
        }
    }

    /// A notification delivered on the main queue, handled on the main actor.
    static func observe(
        _ name: Notification.Name,
        object: AnyObject?,
        _ handler: @escaping @MainActor @Sendable (Notification) -> Void
    ) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { notification in
            MainActor.assumeIsolated {
                handler(notification)
            }
        }
    }

    /// Elapsed time twice a second, on the main queue.
    static func addPeriodicObserver(
        _ player: AVQueuePlayer,
        _ handler: @escaping @MainActor @Sendable (Double) -> Void
    ) -> Any {
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                handler(seconds)
            }
        }
    }

    /// A lock screen, Control Centre, headphone or car command. `handler` gets the
    /// requested position for a seek command and nil for the others.
    ///
    /// On the main thread the handler's own status is returned. Off it, the command
    /// is forwarded to the main actor and reported as handled.
    static func addTarget(
        _ command: MPRemoteCommand,
        _ handler: @escaping @MainActor @Sendable (TimeInterval?) -> MPRemoteCommandHandlerStatus
    ) -> Any {
        command.addTarget { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            if Thread.isMainThread {
                return MainActor.assumeIsolated {
                    handler(position)
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = handler(position)
                }
            }
            return .success
        }
    }

    /// Lock-screen artwork. MediaPlayer asks for the image on a background thread.
    static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in
            image
        }
    }

    private static func onMain(_ handler: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                handler()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    handler()
                }
            }
        }
    }
}
