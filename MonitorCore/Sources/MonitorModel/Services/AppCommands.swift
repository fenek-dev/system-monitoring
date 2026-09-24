import Foundation

/// App-level commands, environment-injected (implemented by the app shell).
public struct AppCommands: Sendable {
    public var openDashboard: @MainActor @Sendable (DashboardPage?) -> Void
    public var inspectApp: @MainActor @Sendable (AppKey) -> Void
    public var openSettings: @MainActor @Sendable () -> Void
    public var setPaused: @MainActor @Sendable (Bool) -> Void
    public var closePopover: @MainActor @Sendable () -> Void
    public var quitTelltale: @MainActor @Sendable () -> Void
    /// Shows or hides the on-screen overlay and persists the new state (same as the global hotkey).
    public var toggleOverlay: @MainActor @Sendable () -> Void

    public init(
        openDashboard: @escaping @MainActor @Sendable (DashboardPage?) -> Void = { _ in },
        inspectApp: @escaping @MainActor @Sendable (AppKey) -> Void = { _ in },
        openSettings: @escaping @MainActor @Sendable () -> Void = {},
        setPaused: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
        closePopover: @escaping @MainActor @Sendable () -> Void = {},
        quitTelltale: @escaping @MainActor @Sendable () -> Void = {},
        toggleOverlay: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.openDashboard = openDashboard
        self.inspectApp = inspectApp
        self.openSettings = openSettings
        self.setPaused = setPaused
        self.closePopover = closePopover
        self.quitTelltale = quitTelltale
        self.toggleOverlay = toggleOverlay
    }

    /// Every command does nothing.
    public static let noop = AppCommands()
}
