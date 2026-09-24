import Foundation
import MonitorModel
import Observation

/// Quit / Force Quit flow for the Processes page (DESIGN §2.25, §2.26, §3.12). Every action goes through the
/// injected `ProcessActions` service. Force Quit always asks first through the injected `confirm` (the shell's
/// window-level `presentConfirmDialog`); without a dialog host nothing is force-quit. Results become the toolbar
/// toast (`ActionFeedback` copy: "{name} quit." / "Asked {name} to quit." / "{name} was force quit." /
/// "Process has exited"), auto-dismissed after 4 s.
@MainActor @Observable
public final class ProcessActionCoordinator {
    public struct Toast: Equatable, Sendable {
        public var id: Int
        public var text: String
    }

    /// (title, message, confirmTitle) → true only when confirmed.
    public typealias Confirm = @MainActor (String, String, String) async -> Bool

    public private(set) var toast: Toast?
    /// PID being sampled (the [Sample] button shows "Sampling…" and is disabled meanwhile).
    public private(set) var samplingPID: Int32?
    @ObservationIgnored public var actions: ProcessActions
    @ObservationIgnored public var confirm: Confirm?
    @ObservationIgnored public var sampler: any ProcessSampling
    @ObservationIgnored private var toastCounter = 0

    /// Toast lifetime (DESIGN §3.12).
    public nonisolated static let toastDuration: Duration = .seconds(4)

    public init(actions: ProcessActions = .noop, confirm: Confirm? = nil,
                sampler: any ProcessSampling = LiveProcessSampler()) {
        self.actions = actions
        self.confirm = confirm
        self.sampler = sampler
    }

    /// [Sample] (DESIGN §3.12, §6.23): 3-s `sample` of the row's (responsible) process through the injected sampler,
    /// then reveals the report in Finder; failures toast. One sample at a time. The process identity (pid + start
    /// time) is re-verified right before spawning, so a reused pid is never sampled ("Process has exited").
    public func sample(_ process: ProcessID, name: String) async {
        guard samplingPID == nil else { return }
        let started = sampler.startTimeUs(pid: process.pid)
        guard let started, process.startTimeUs == 0 || started == process.startTimeUs else {
            toastCounter += 1
            toast = Toast(id: toastCounter, text: ActionFeedback.exited)
            return
        }
        samplingPID = process.pid
        let result = await sampler.sample(pid: process.pid, name: name)
        samplingPID = nil
        switch result {
        case .done(let url):
            sampler.reveal(url)
        case .failed(let why):
            toastCounter += 1
            toast = Toast(id: toastCounter, text: "Couldn’t sample \(name): \(why)")
        }
    }

    public func quit(_ target: ProcessTarget) async {
        let result = await actions.quit(target)
        report(target, result, force: false)
    }

    /// Asks for confirmation (DESIGN §3.12 copy), then force-quits through the service. Cancel → nothing sent.
    public func forceQuit(_ target: ProcessTarget) async {
        guard let confirm else { return }
        let confirmed = await confirm(Self.dialogTitle(target), Self.dialogMessage, "Force Quit")
        guard confirmed else { return }
        let result = await actions.forceQuit(target)
        report(target, result, force: true)
    }

    /// Row-menu Quit results (the menu performs the action itself, `\.onProcessActionResult`).
    public func report(_ target: ProcessTarget, _ result: ActionResult, force: Bool) {
        guard let text = ActionFeedback.message(force ? .forceQuit : .quit, result, name: Self.name(of: target))
        else { return }
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
