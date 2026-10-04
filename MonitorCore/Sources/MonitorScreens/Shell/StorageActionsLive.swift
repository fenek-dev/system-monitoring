import AppKit
import Foundation
import MonitorModel

/// The AppKit and Settings pieces of the storage backend (spec §3.8). The engine (`MonitorRuntime`) takes
/// `platform()`; `decorate` fills the actions the engine does not own. Lives in Shell so `swift test` covers it.
public enum StorageActionsLive {
    static let fullDiskAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// `center`: tests post `willUnmountNotification` on their own center.
    @MainActor
    public static func platform(center: NotificationCenter? = nil) -> StoragePlatform {
        let center = center ?? NSWorkspace.shared.notificationCenter
        return StoragePlatform(
            runningBundleIDs: {
                await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
            },
            appPaths: { bundleID in
                await MainActor.run {
                    NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map(\.path)
                }
            },
            willUnmount: { unmountPaths(center: center) })
    }

    /// Mount points about to unmount; the observer lives as long as the stream is consumed.
    static func unmountPaths(center: NotificationCenter) -> AsyncStream<String> {
        AsyncStream { continuation in
            let watcher = Task {
                for await note in center.notifications(named: NSWorkspace.willUnmountNotification) {
                    // "NSDevicePath": the volume's mount point (NSWorkspace.h, Will/DidUnmount).
                    if let path = note.userInfo?["NSDevicePath"] as? String { continuation.yield(path) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in watcher.cancel() }
        }
    }

    @MainActor
    public static func decorate(_ base: StorageActions, settings: SettingsStore) -> StorageActions {
        var actions = base
        actions.ignore = { settings.storageIgnoredPaths.insert($0) }
        actions.unignore = { settings.storageIgnoredPaths.remove($0) }
        actions.revealInFinder = { path in
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        actions.openFDASettings = {
            guard let url = URL(string: fullDiskAccessURL) else { return }
            NSWorkspace.shared.open(url)
        }
        return actions
    }
}
