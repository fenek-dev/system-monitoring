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
public struct TTRowActionsButton: View {
    let target: ProcessTarget
    let name: String
    @State private var hovering = false

    public init(target: ProcessTarget, name: String) {
        self.target = target
        self.name = name
    }

    public var body: some View {
        Menu {
            TTRowActionsMenu(target: target)
        } label: {
            TTIcon(.ellipsis, size: 16, color: TTColor.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: TTRadius.r5, style: .continuous)
                    .fill(hovering ? TTColor.fillIconButton : .clear))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Actions for \(name)")
        .accessibilityLabel("Actions for \(name)")
    }
}
