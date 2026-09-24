import Foundation

/// What a row action acts on. Members are full `ProcessID`s (pid + start time) so the live service can re-verify
/// each one right before signalling and never hit a reused pid.
public enum ProcessTarget: Sendable, Hashable {
    case app(AppIdentity, processes: [ProcessID])
    case process(ProcessID, name: String, path: String?, uid: UInt32)

    public var processIDs: [ProcessID] {
        switch self {
        case .app(_, let ids): ids
        case .process(let id, _, _, _): [id]
        }
    }

    public var pids: [Int32] { processIDs.map(\.pid) }

    /// The one self rule (DESIGN §2.25) shared by the menu, inline actions and the live service: the target is
    /// Telltale when it contains our pid, or is the app group with our bundle id.
    public func isSelf(ownPID: Int32, ownBundleID: String?) -> Bool {
        switch self {
        case .app(let identity, let ids):
            ids.contains { $0.pid == ownPID }
                || (ownBundleID != nil && identity.key.kind == .app && identity.key.id == ownBundleID)
        case .process(let id, _, _, _):
            id.pid == ownPID
        }
    }
}

/// - `done`: the action finished (the process is gone, or the eject completed).
/// - `requested`: a graceful quit was sent but the process was still running when we stopped waiting (the app may
///   be asking to save, or may refuse): "Asked {name} to quit."
/// - `exited`: every target process had already exited (or its pid was reused); no signal sent.
public enum ActionResult: Sendable, Equatable { case done, requested, exited, notPermitted, failed(String), cancelled }

/// Process/volume actions, environment-injected (live implementation in the app, `ActionLog` in mocks).
public struct ProcessActions: Sendable {
    /// False for root/other users, synthetic rows and Telltale itself.
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
