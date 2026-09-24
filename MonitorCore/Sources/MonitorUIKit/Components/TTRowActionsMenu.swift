import AppKit
import Darwin
import MonitorModel
import SwiftUI

/// DESIGN §2.25 row actions — the menu items, for `.contextMenu { }` or a `Menu { }` (native dark `NSMenu`):
/// [Owned by {user}] · Quit · Force Quit… · — · Reveal in Finder · Open in Activity Monitor.
/// - Not controllable (`processActions.canControl == false`): Quit/Force Quit disabled, "Owned by {user}" header.
/// - Telltale itself: Quit quits Telltale (`appCommands.quitTelltale`), Force Quit hidden.
/// - Force Quit… asks the page to confirm (`\.requestForceQuit`); disabled when no page handler is installed.
/// - Reveal disabled without a path.
public struct TTRowActionsMenu: View {
    let target: ProcessTarget
    @Environment(\.processActions) private var actions
    @Environment(\.appCommands) private var commands
    @Environment(\.requestForceQuit) private var requestForceQuit
    @Environment(\.onProcessActionResult) private var onResult

    public init(target: ProcessTarget) { self.target = target }

    /// Pure model of the menu (tested).
    public struct Model: Equatable, Sendable {
        public var ownerHeader: String?
        public var quitEnabled: Bool
        public var forceQuitVisible: Bool
        public var forceQuitEnabled: Bool
        public var revealEnabled: Bool
        public var quitsTelltale: Bool
    }

    public nonisolated static func model(target: ProcessTarget, canControl: Bool, hasForceQuitHandler: Bool,
                                         ownPID: Int32 = getpid(), ownBundleID: String? = Bundle.main.bundleIdentifier,
                                         userName: (UInt32) -> String = TTRowActionsMenu.userName) -> Model {
        let isSelf: Bool
        let path: String?
        var owner: String?
        switch target {
        case .app(let identity, let pids):
            isSelf = pids.contains(ownPID) || (ownBundleID != nil && identity.key.kind == .app && identity.key.id == ownBundleID)
            path = identity.bundlePath
            if !canControl { owner = "another user" }
        case .process(let pid, _, let p, let uid):
            isSelf = pid == ownPID
            path = p
            if !canControl { owner = userName(uid) }
        }
        return Model(
            ownerHeader: isSelf ? nil : owner.map { "Owned by \($0)" },
            quitEnabled: isSelf || canControl,
            forceQuitVisible: !isSelf,
            forceQuitEnabled: canControl && hasForceQuitHandler && !isSelf,
            revealEnabled: path != nil,
            quitsTelltale: isSelf
        )
    }

    public nonisolated static func userName(_ uid: UInt32) -> String {
        guard let pw = getpwuid(uid), let name = pw.pointee.pw_name else { return "uid \(uid)" }
        return String(cString: name)
    }

    public var body: some View {
        let m = Self.model(target: target, canControl: actions.canControl(target),
                           hasForceQuitHandler: requestForceQuit != nil)
        if let header = m.ownerHeader {
            Section(header) { items(m) }
        } else {
            items(m)
        }
    }

    @ViewBuilder private func items(_ m: Model) -> some View {
        Button("Quit") {
            if m.quitsTelltale {
                commands.quitTelltale()
            } else {
                let target = target, actions = actions, onResult = onResult
                Task { @MainActor in
                    let result = await actions.quit(target)
                    onResult?(target, result)
                }
            }
        }
        .disabled(!m.quitEnabled)
        if m.forceQuitVisible {
            Button("Force Quit…") { requestForceQuit?(target) }
                .disabled(!m.forceQuitEnabled)
        }
        Divider()
        Button("Reveal in Finder") { actions.revealInFinder(target) }
            .disabled(!m.revealEnabled)
        Button("Open in Activity Monitor") { actions.openInActivityMonitor(target) }
    }
}

/// DESIGN §2.14 `rowAction` button (24, radius 5, `ellipsis` 16) opening `TTRowActionsMenu`.
/// Tooltip/label "Actions for {name}".
/// A plain 24×24 SwiftUI button (the whole square is the hit target, §0) that pops up the same actions as a native
/// `NSMenu` below itself (`NSMenu.popUp(positioning:at:in:)`), with the same items and enablement as
/// `TTRowActionsMenu`.
public struct TTRowActionsButton: View {
    let target: ProcessTarget
    let name: String
    @State private var hovering = false
    @State private var anchor = MenuAnchor()
    @Environment(\.processActions) private var actions
    @Environment(\.appCommands) private var commands
    @Environment(\.requestForceQuit) private var requestForceQuit
    @Environment(\.onProcessActionResult) private var onResult

    public static let side: CGFloat = 24

    public init(target: ProcessTarget, name: String) {
        self.target = target
        self.name = name
    }

    public var body: some View {
        Button(action: popUp) {
            TTIcon(.ellipsis, size: 16, color: TTColor.textSecondary)
                .frame(width: Self.side, height: Self.side)
                .background(RoundedRectangle(cornerRadius: TTRadius.r5, style: .continuous)
                    .fill(hovering ? TTColor.fillIconButton : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: Self.side, height: Self.side)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { hovering = $0 }
        .help("Actions for \(name)")
        .accessibilityLabel("Actions for \(name)")
    }

    private func popUp() {
        guard let view = anchor.view else { return }
        let menu = TTRowActionsMenu.nsMenu(target: target, actions: actions, commands: commands,
                                           requestForceQuit: requestForceQuit, onResult: onResult)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 2 : -2), in: view)
    }
}

/// Holds the AppKit view the menu pops up from.
@MainActor final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        anchor.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { anchor.view = nsView }
}

extension TTRowActionsMenu {
    /// Native menu with the same items/enablement as the SwiftUI `body` (tested via `model`).
    static func nsMenu(target: ProcessTarget, actions: ProcessActions, commands: AppCommands,
                       requestForceQuit: (@MainActor @Sendable (ProcessTarget) -> Void)?,
                       onResult: (@MainActor @Sendable (ProcessTarget, ActionResult) -> Void)?) -> NSMenu {
        let m = model(target: target, canControl: actions.canControl(target), hasForceQuitHandler: requestForceQuit != nil)
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let header = m.ownerHeader { menu.addItem(NSMenuItem.sectionHeader(title: header)) }
        menu.addItem(ClosureMenuItem("Quit", enabled: m.quitEnabled) {
            if m.quitsTelltale {
                commands.quitTelltale()
            } else {
                Task { @MainActor in onResult?(target, await actions.quit(target)) }
            }
        })
        if m.forceQuitVisible {
            menu.addItem(ClosureMenuItem("Force Quit…", enabled: m.forceQuitEnabled) { requestForceQuit?(target) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Reveal in Finder", enabled: m.revealEnabled) { actions.revealInFinder(target) })
        menu.addItem(ClosureMenuItem("Open in Activity Monitor", enabled: true) { actions.openInActivityMonitor(target) })
        return menu
    }
}

/// `NSMenuItem` that runs a closure (it is its own target).
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor @Sendable () -> Void

    init(_ title: String, enabled: Bool, handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not coded") }

    /// Menu actions are delivered on the main thread.
    @objc private func run() {
        let h = handler
        MainActor.assumeIsolated { h() }
    }
}
