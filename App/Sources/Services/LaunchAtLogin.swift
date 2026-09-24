import Foundation
import MonitorScreens
import os
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (DESIGN §3.14). Registration only sticks for an app at a stable
/// path (`scripts/install.sh` → ~/Applications/Telltale.app).
@MainActor
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "dev.telltale", category: "App")

    static var status: LoginItemControl.Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .disabled
        // Never registered yet also reports `.notFound`; only a build outside an Applications folder is a problem.
        case .notFound: isStablePath ? .disabled : .unavailable("Install with scripts/install.sh to enable launch at login")
        @unknown default: .disabled
        }
    }

    /// `/Applications/…` or `~/Applications/…` (worktree Debug builds are not).
    static var isStablePath: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }

    static func setEnabled(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        log.notice("launch at login \(on ? "register" : "unregister", privacy: .public) → \(String(describing: SMAppService.mainApp.status.rawValue), privacy: .public)")
    }

    static var control: LoginItemControl {
        LoginItemControl(status: { status }, setEnabled: { try setEnabled($0) },
                         openSystemSettings: { SMAppService.openSystemSettingsLoginItems() })
    }
}
