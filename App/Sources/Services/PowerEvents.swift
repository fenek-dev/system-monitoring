import AppKit
import os

/// System sleep/wake → runtime (ARCHITECTURE §5.13). Only `willSleep`/`didWake`: screen lock, screensaver and
/// display sleep are not system sleep and keep sampling (the UI is closed then anyway → background mode).
@MainActor
final class PowerEvents {
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "dev.telltale", category: "App")

    init(willSleep: @escaping @MainActor () -> Void, didWake: @escaping @MainActor () -> Void) {
        let nc = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [log] _ in
                MainActor.assumeIsolated {
                    log.notice("system will sleep")
                    willSleep()
                }
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [log] _ in
                MainActor.assumeIsolated {
                    log.notice("system did wake")
                    didWake()
                }
            },
        ]
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }
}
