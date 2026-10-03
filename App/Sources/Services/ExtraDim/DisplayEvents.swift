import AppKit

/// Moments the gamma table may have been reset or the built-in display may have gone (extra-dim spec §5.4):
/// system wake, screens wake, unlock (distributed `com.apple.screenIsUnlocked`), screen parameters changed.
@MainActor
final class DisplayEvents {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(changed: @escaping @MainActor () -> Void) {
        let handler: @Sendable (Notification) -> Void = { _ in MainActor.assumeIsolated { changed() } }
        let ws = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        observers = [
            (ws, ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: handler)),
            (ws, ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main,
                                using: handler)),
            (dnc, dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main,
                                  using: handler)),
            (NotificationCenter.default,
             NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                    object: nil, queue: .main, using: handler)),
        ]
    }

    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
    }
}
