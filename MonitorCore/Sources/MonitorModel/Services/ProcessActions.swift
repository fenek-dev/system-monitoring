import Foundation

public enum ProcessTarget: Sendable, Hashable {
    case app(AppIdentity, pids: [Int32])
    case process(pid: Int32, name: String, path: String?, uid: UInt32)
}

public enum ActionResult: Sendable, Equatable { case done, notPermitted, failed(String), cancelled }

/// Process/volume actions, environment-injected (live implementation in the app, `ActionLog` in mocks).
public struct ProcessActions: Sendable {
    /// False for root/other users and synthetic rows.
    public var canControl: @MainActor @Sendable (ProcessTarget) -> Bool
    public var quit: @MainActor @Sendable (ProcessTarget) async -> ActionResult
    public var forceQuit: @MainActor @Sendable (ProcessTarget) async -> ActionResult
    public var revealInFinder: @MainActor @Sendable (ProcessTarget) -> Void
    public var openInActivityMonitor: @MainActor @Sendable (ProcessTarget) -> Void
    public var eject: @MainActor @Sendable (VolumeInfo) async -> ActionResult

    public init(
        canControl: @escaping @MainActor @Sendable (ProcessTarget) -> Bool = { _ in false },
        quit: @escaping @MainActor @Sendable (ProcessTarget) async -> ActionResult = { _ in .cancelled },
        forceQuit: @escaping @MainActor @Sendable (ProcessTarget) async -> ActionResult = { _ in .cancelled },
        revealInFinder: @escaping @MainActor @Sendable (ProcessTarget) -> Void = { _ in },
        openInActivityMonitor: @escaping @MainActor @Sendable (ProcessTarget) -> Void = { _ in },
        eject: @escaping @MainActor @Sendable (VolumeInfo) async -> ActionResult = { _ in .cancelled }
    ) {
        self.canControl = canControl
        self.quit = quit
        self.forceQuit = forceQuit
        self.revealInFinder = revealInFinder
        self.openInActivityMonitor = openInActivityMonitor
        self.eject = eject
    }

    /// Nothing controllable; every action returns `.cancelled` or does nothing.
    public static let noop = ProcessActions()
}
