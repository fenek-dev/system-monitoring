import AppKit
import Foundation
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("Shell storage (ShellStorageTests)") @MainActor
struct ShellStorageTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Bug: an ignored path is lost on relaunch, or `unignore` cannot take it back.
    @Test func ignoreSurvivesRelaunchAndUnignoreClears() {
        let defaults = InMemoryDefaults()
        let settings = SettingsStore(defaults: defaults)
        let actions = StorageActionsLive.decorate(StorageActions(), settings: settings)

        actions.ignore("/Users/me/Library/Caches/com.example")
        #expect(SettingsStore(defaults: defaults).classifyOptions(now: now).ignoredPaths
            == ["/Users/me/Library/Caches/com.example"])

        actions.unignore("/Users/me/Library/Caches/com.example")
        #expect(SettingsStore(defaults: defaults).classifyOptions(now: now).ignoredPaths.isEmpty)
    }

    /// Bug: a zero, negative or non-numeric threshold in the defaults reaches the classifier (everything is
    /// "large", or nothing is).
    @Test func invalidThresholdsFallBackToDefaults() {
        for stored in [0, -5] as [Int] {
            expectDefaults(stored: stored)
        }
        expectDefaults(stored: "big")
    }

    private func expectDefaults(stored: Any) {
        let defaults = InMemoryDefaults()
        defaults.set(stored, forKey: SettingsStore.Key.storageLargeThreshold)
        defaults.set(stored, forKey: SettingsStore.Key.storageOldThreshold)
        let options = SettingsStore(defaults: defaults).classifyOptions(now: now)
        #expect(options.largeBytes == ClassifyOptions.defaultLargeBytes)
        #expect(options.oldBytes == ClassifyOptions.defaultOldBytes)
    }

    @Test func validThresholdsAreUsed() {
        let defaults = InMemoryDefaults()
        defaults.set(UInt64(2_000_000_000), forKey: SettingsStore.Key.storageLargeThreshold)
        defaults.set(UInt64(10_000_000), forKey: SettingsStore.Key.storageOldThreshold)
        let options = SettingsStore(defaults: defaults).classifyOptions(now: now)
        #expect(options.largeBytes == 2_000_000_000)
        #expect(options.oldBytes == 10_000_000)
    }

    /// Bug: ejecting a volume never cancels its scan (the notification's mount point never reaches the engine).
    @Test func willUnmountYieldsTheNotifiedMountPoint() async {
        let center = NotificationCenter()
        let platform = StorageActionsLive.platform(center: center)
        let stream = platform.willUnmount()
        let paths = Task { () -> String? in
            for await path in stream { return path }
            return nil
        }
        // The observer registers inside the stream's task: post until it is consumed.
        let poster = Task {
            while !Task.isCancelled {
                center.post(name: NSWorkspace.willUnmountNotification, object: nil,
                            userInfo: ["NSDevicePath": "/Volumes/Backup"])
                await Task.yield()
            }
        }
        let received = await paths.value
        poster.cancel()
        #expect(received == "/Volumes/Backup")
    }
}
