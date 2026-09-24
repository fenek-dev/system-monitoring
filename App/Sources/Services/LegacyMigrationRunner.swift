import AppKit
import MonitorScreens
import os
import ServiceManagement

/// App side of `LegacyMigration` (Telltale → Warden): real directories and defaults domains. Runs first thing at
/// launch, before the instance lock and the stores. Never runs the old Telltale binary (ruling R-B).
@MainActor
enum LegacyMigrationRunner {
    private static let log = Logger(subsystem: "dev.telltale", category: "Migration")

    /// Returns the defaults holding the migration marker (for `showNoticeIfPending`), nil when not applicable.
    @discardableResult
    static func run(_ options: LaunchOptions) -> UserDefaults? {
        guard let (migration, marker) = options.dataDirectory.map(devMigration) ?? productionMigration() else {
            return nil
        }
        let out = migration.run()
        if !out.alreadyDone {
            log.notice("""
                legacy migration completed=\(out.completed) data=\(String(describing: out.data), privacy: .public) \
                keys=\(out.copiedKeys) loginItem=\(out.loginItemRegistered)
                """)
        }
        return marker
    }

    /// One-time alert after a migration that moved data or settings (`LegacyMigration.noticeText`).
    static func showNoticeIfPending(_ marker: UserDefaults?) {
        guard let marker, LegacyMigration.takeNotice(marker) else { return }
        let alert = NSAlert()
        alert.messageText = "Warden replaced Telltale"
        alert.informativeText = LegacyMigration.noticeText
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    /// Installed app: `~/Library/Application Support/dev.telltale` → `dev.warden`, domain `dev.telltale.Telltale`
    /// → this bundle's domain. Launch at login: Telltale never stored it in its defaults (it read
    /// `SMAppService.mainApp` only), so it can't be detected and is left alone; the notice covers it.
    private static func productionMigration() -> (LegacyMigration, UserDefaults)? {
        let old = AppEnvironment.legacyDataDirectory()
        let newName = Bundle.main.bundleIdentifier ?? "dev.warden.Warden"
        let oldName = LegacyMigration.legacyBundleID
        guard newName != oldName else { return nil }
        let m = LegacyMigration(
            legacyDataDirectory: old, dataDirectory: AppEnvironment.defaultDataDirectory(),
            defaults: [(from: domain(oldName), to: domain(newName))], marker: .standard,
            legacyInstanceRunning: { legacyInstanceHolds(old) },
            legacyLoginItem: { _ in nil },
            loginItemEnabled: { SMAppService.mainApp.status == .enabled },
            enableLoginItem: { try LaunchAtLogin.setEnabled(true) })
        return (m, .standard)
    }

    /// Worktree builds (`TELLTALE_DATA_DIR`): the data dir keeps its path; only the per-dir suite is renamed.
    private static func devMigration(_ dir: URL) -> (LegacyMigration, UserDefaults)? {
        let oldName = SettingsStore.legacySuiteName(for: dir), newName = SettingsStore.suiteName(for: dir)
        guard let marker = UserDefaults(suiteName: newName) else { return nil }
        let m = LegacyMigration(legacyDataDirectory: nil, dataDirectory: nil,
                                defaults: [(from: domain(oldName), to: domain(newName))], marker: marker,
                                legacyInstanceRunning: { false })
        return (m, marker)
    }

    /// Read and replace a whole persistent domain (one write: `setPersistentDomain`).
    private static func domain(_ name: String) -> LegacyMigration.Domain {
        LegacyMigration.Domain(persisted: { UserDefaults.standard.persistentDomain(forName: name) ?? [:] },
                               replace: { UserDefaults.standard.setPersistentDomain($0, forName: name) })
    }

    /// A Telltale still running on the old data dir holds its instance lock.
    private static func legacyInstanceHolds(_ dir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        if case .heldByAnotherInstance = InstanceLock.acquire(dataDirectory: dir) { return true }
        return false
    }
}
