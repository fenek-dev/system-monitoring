import AppKit
import MonitorLive
import MonitorModel
import MonitorRuntime
import MonitorScreens
import os

/// Composition root (ARCHITECTURE §5.11): launch options → data dir, settings suite, runtime.
/// Controllers read everything from here; the SwiftUI trees get it through `context()`.
@MainActor
final class AppEnvironment {
    let options: LaunchOptions
    let dataDirectory: URL
    let settings: SettingsStore
    let runtime: TelltaleRuntime
    let navigation = NavigationModel()
    /// Set by `AppDelegate` once the controllers exist.
    var commands: AppCommands = .noop
    var processActions: ProcessActions = .noop

    static let log = Logger(subsystem: "dev.telltale", category: "App")

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        let options = LaunchOptions.parse(arguments: arguments, environment: environment)
        self.options = options
        dataDirectory = options.dataDirectory ?? Self.defaultDataDirectory()
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        settings = SettingsStore(defaults: SettingsStore.defaults(for: options.dataDirectory))

        let mode: RuntimeMode = options.mockScenario.map { .mock($0) } ?? .live
        let disabled = options.disabledSensors.union(settings.disabledSensors)
        #if DEBUG
        let crash = options.crashSensor
        #else
        let crash: SensorID? = nil
        #endif
        runtime = TelltaleRuntime.make(mode: mode, dataDirectory: dataDirectory, disabledSensors: disabled,
                                       crashSensor: crash)
        Self.log.info("""
            launch mode=\(String(describing: mode), privacy: .public) data=\(self.dataDirectory.path, privacy: .public) \
            disabled=\(disabled.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)
            """)
    }

    var live: LiveModel { runtime.live }

    /// Environment for a new hosting view (popover, dashboard, settings).
    func context() -> ShellContext {
        ShellContext(live: runtime.live, navigation: navigation, settings: settings, history: runtime.history,
                     processActions: processActions, appCommands: commands)
    }

    static func defaultDataDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Telltale", isDirectory: true)
    }
}
