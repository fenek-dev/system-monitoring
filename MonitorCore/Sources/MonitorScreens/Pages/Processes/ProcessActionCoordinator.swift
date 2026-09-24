import Foundation
import MonitorModel
import Observation

/// Quit / Force Quit flow for the Processes page (DESIGN §2.25, §2.26, §3.12). Every action goes through the
/// injected `ProcessActions` service; Force Quit always asks first (`pendingForceQuit` drives `TTConfirmDialog`).
/// Results become the toolbar toast ("{name} quit." / "{name} was force quit."), auto-dismissed after 4 s.
@MainActor @Observable
public final class ProcessActionCoordinator {
    public struct Toast: Equatable, Sendable {
        public var id: Int
        public var text: String
    }

    public private(set) var pendingForceQuit: ProcessTarget?
    public private(set) var toast: Toast?
    @ObservationIgnored public var actions: ProcessActions
    @ObservationIgnored private var toastCounter = 0

    /// Toast lifetime (DESIGN §3.12).
    public nonisolated static let toastDuration: Duration = .seconds(4)

    public init(actions: ProcessActions = .noop) {
        self.actions = actions
    }

    public func quit(_ target: ProcessTarget) async {
        let result = await actions.quit(target)
        report(target, result, force: false)
    }

    /// Opens the confirm dialog; nothing is sent to the process yet.
    public func requestForceQuit(_ target: ProcessTarget) {
        pendingForceQuit = target
    }

    public func cancelForceQuit() {
        pendingForceQuit = nil
    }

    public func confirmForceQuit() async {
        guard let target = pendingForceQuit else { return }
        pendingForceQuit = nil
        let result = await actions.forceQuit(target)
        report(target, result, force: true)
    }

    /// Row-menu Quit results (the menu performs the action itself, `\.onProcessActionResult`).
    public func report(_ target: ProcessTarget, _ result: ActionResult, force: Bool) {
        let name = Self.name(of: target)
        let text: String?
        switch result {
        case .done: text = force ? "\(name) was force quit." : "\(name) quit."
        case .notPermitted: text = "Not permitted to quit \(name)."
        case .failed(let why): text = "Couldn’t quit \(name): \(why)"
        case .cancelled: text = nil
        }
        guard let text else { return }
        toastCounter += 1
        toast = Toast(id: toastCounter, text: text)
    }

    /// Clears the toast if it is still `id` (called 4 s after it appeared).
    public func dismissToast(_ id: Int) {
        if toast?.id == id { toast = nil }
    }

    /// Dialog copy (DESIGN §3.12).
    public static func dialogTitle(_ target: ProcessTarget) -> String { "Force quit “\(name(of: target))”?" }
    public static let dialogMessage = "Unsaved changes will be lost. The process ends immediately without cleanup."

    public nonisolated static func name(of target: ProcessTarget) -> String {
        switch target {
        case .app(let identity, _): identity.displayName
        case .process(_, let name, _, _): name
        }
    }
}
