import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Everything a Telltale view tree reads from the environment (ARCHITECTURE §5.10), built once by the app
/// (`App/Composition`) or by `ScreenCatalog` for renders and snapshot tests.
@MainActor
public struct ShellContext {
    public var live: LiveModel
    public var navigation: NavigationModel
    public var settings: SettingsStore
    public var history: any HistoryProvider
    public var processActions: ProcessActions
    public var appCommands: AppCommands
    /// Storage page state (injected as an observable) and its actions (`\.storageActions`).
    public var storage: StorageModel
    public var storageActions: StorageActions
    public var isSnapshot: Bool
    public var now: Date?
    /// Observed by the environment: a window built before the store finished opening updates when it resolves.
    public var historyStatus: HistoryStatus
    /// Observed by the environment (`\.overlayHotKeyStatus`): the App re-publishes it on each registration.
    public var hotKeyState: HotKeyState
    /// False when the store fell back to memory (open failure) → History shows "History unavailable" (§6.6).
    /// Setting it gives this context its own status (copies of a context don't share the change).
    public var historyPersistent: Bool {
        get { historyStatus.persistent }
        set { historyStatus = HistoryStatus(persistent: newValue) }
    }

    public init(live: LiveModel, navigation: NavigationModel = NavigationModel(), settings: SettingsStore,
                history: any HistoryProvider = EmptyHistoryProvider(), processActions: ProcessActions = .noop,
                appCommands: AppCommands = .noop, isSnapshot: Bool = false, now: Date? = nil,
                historyStatus: HistoryStatus = HistoryStatus(), hotKeyState: HotKeyState = HotKeyState(),
                storage: StorageModel = StorageModel(actions: .noop), storageActions: StorageActions = .noop) {
        self.storage = storage
        self.storageActions = storageActions
        self.historyStatus = historyStatus
        self.hotKeyState = hotKeyState
        self.live = live
        self.navigation = navigation
        self.settings = settings
        self.history = history
        self.processActions = processActions
        self.appCommands = appCommands
        self.isSnapshot = isSnapshot
        self.now = now
    }
}

/// Whether history is stored on disk this launch. The live store opens in the background, so this starts true
/// (the runtime's value until the open finishes) and `resolve` publishes the final value once it is known.
@MainActor @Observable public final class HistoryStatus {
    public var persistent: Bool

    public init(persistent: Bool = true) {
        self.persistent = persistent
    }

    /// Awaits `ready` (e.g. `runtime.historyReady()` then `runtime.historyPersistent`) without blocking the
    /// MainActor, then publishes it; views built earlier pick it up through observation.
    public func resolve(_ ready: () async -> Bool) async {
        persistent = await ready()
    }
}

public extension EnvironmentValues {
    /// `TelltaleRuntime.historyPersistent`: false when the history store runs in memory (open failure,
    /// ARCHITECTURE §6.6); HistoryPage (W5c) shows "History unavailable". Default true (renders, previews).
    @Entry var historyPersistent: Bool = true
}

public extension View {
    /// Injects `LiveModel`, `NavigationModel`, `SettingsStore` (observables) and the §5.10 environment values.
    /// `unitPreferences`/`popoverLayout` follow the settings store live. Snapshot contexts also pin locale,
    /// time zone and color scheme (ARCHITECTURE §8 determinism).
    func telltaleEnvironment(_ context: ShellContext) -> some View {
        modifier(ShellEnvironmentModifier(context: context))
    }
}

private struct ShellEnvironmentModifier: ViewModifier {
    let context: ShellContext

    func body(content: Content) -> some View {
        let settings = context.settings
        let base = content
            .environment(context.live)
            .environment(context.navigation)
            .environment(settings)
            .environment(\.unitPreferences, settings.units)
            .environment(\.popoverLayout, settings.popoverLayout)
            .environment(\.historyProvider, context.history)
            .environment(\.processActions, context.processActions)
            .environment(\.appCommands, context.appCommands)
            .environment(context.storage)
            .environment(\.storageActions, context.storageActions)
            .environment(\.isSnapshot, context.isSnapshot)
            .environment(\.now, context.now)
            .environment(\.historyPersistent, context.historyStatus.persistent)      // observed: follows resolve
            .environment(\.overlayHotKeyStatus, context.hotKeyState.status)            // observed: follows the App
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
        if context.isSnapshot {
            base
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.timeZone, TimeZone(identifier: "Europe/London") ?? .current)
        } else {
            base
        }
    }
}
