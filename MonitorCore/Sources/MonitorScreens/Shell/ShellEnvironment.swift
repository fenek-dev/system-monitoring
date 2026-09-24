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
    public var isSnapshot: Bool
    public var now: Date?

    public init(live: LiveModel, navigation: NavigationModel = NavigationModel(), settings: SettingsStore,
                history: any HistoryProvider = EmptyHistoryProvider(), processActions: ProcessActions = .noop,
                appCommands: AppCommands = .noop, isSnapshot: Bool = false, now: Date? = nil) {
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
            .environment(\.isSnapshot, context.isSnapshot)
            .environment(\.now, context.now)
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
