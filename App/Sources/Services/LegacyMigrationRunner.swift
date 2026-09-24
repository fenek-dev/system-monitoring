import AppKit
import MonitorScreens
import os
import ServiceManagement
import SQLite3

/// App side of `LegacyMigration` (Telltale → Warden): real directories and defaults domains. Runs first thing at
/// launch, before the instance lock and the stores. Never runs the old Telltale binary (ruling R-B).
@MainActor
enum LegacyMigrationRunner {
    private static let log = Logger(subsystem: "dev.telltale", category: "Migration")

    /// Migrates once. A running Telltale (`.legacyInUse`): alert, then exit before anything of Warden's exists.
    /// After a migration that moved something, the one-time notice is scheduled for after launch.
    static func run(_ options: LaunchOptions) {
        guard let (migration, marker) = options.dataDirectory.map(devMigration) ?? productionMigration() else {
            return
        }
        let out = migration.run()
        if out.alreadyDone { return }
        log.notice("""
            legacy migration completed=\(out.completed) data=\(String(describing: out.data), privacy: .public) \
            keys=\(out.copiedKeys) loginItem=\(out.loginItemRegistered)
            """)
        if out.data == .legacyInUse {
            let alert = NSAlert()
            alert.messageText = LegacyMigration.legacyRunningText
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            alert.runModal()                                         // synchronous launch path, not a Task
            exit(0)
        }
        if LegacyMigration.takeNotice(marker) {
            // Off the launch call and outside Swift concurrency: `runModal` in a MainActor Task would hold the
            // main queue for as long as the alert is up.
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { showNotice() }
            }
        }
    }

    /// "Warden replaced Telltale…" once, with "Open at Login" (launch at login can't be carried over). The button
    /// only for an installed copy (`/Applications`, `~/Applications`): a worktree build must never become a login item.
    private static func showNotice() {
        let alert = NSAlert()
        alert.messageText = "Warden replaced Telltale"
        alert.addButton(withTitle: "OK")
        let offerLogin = LaunchAtLogin.isStablePath && SMAppService.mainApp.status != .enabled
        if offerLogin {
            alert.informativeText = LegacyMigration.noticeText
            alert.addButton(withTitle: LegacyMigration.noticeLoginButton)
        } else {
            alert.informativeText = LegacyMigration.noticeTextWithoutLogin
        }
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn, offerLogin else { return }
        do {
            try LaunchAtLogin.setEnabled(true)
        } catch {
            log.error("open at login failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Installed app: `~/Library/Application Support/dev.telltale` → `dev.warden`, domain `dev.telltale.Telltale`
    /// → this bundle's domain. Launch at login: Telltale never stored it in its defaults (it read
    /// `SMAppService.mainApp` only), so it can't be detected; the notice offers "Open at Login".
    private static func productionMigration() -> (LegacyMigration, UserDefaults)? {
        let old = AppEnvironment.legacyDataDirectory()
        let newName = Bundle.main.bundleIdentifier ?? "dev.warden.Warden"
        let oldName = LegacyMigration.legacyBundleID
        guard newName != oldName else { return nil }
        let m = LegacyMigration(
            legacyDataDirectory: old, dataDirectory: AppEnvironment.defaultDataDirectory(),
            defaults: [(from: domain(oldName), to: domain(newName))], marker: .standard,
            lockLegacy: { lockLegacy(old) },
            newDataIsDisposable: { LegacyMigration.onlyLockOrEmptyFiles($0) || holdsOnlyAnEmptyStore($0) },
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
                                defaults: [(from: domain(oldName), to: domain(newName))], marker: marker)
        return (m, marker)
    }

    /// Read and replace a whole persistent domain (one write: `setPersistentDomain`).
    private static func domain(_ name: String) -> LegacyMigration.Domain {
        LegacyMigration.Domain(persisted: { UserDefaults.standard.persistentDomain(forName: name) ?? [:] },
                               replace: { UserDefaults.standard.setPersistentDomain($0, forName: name) })
    }

    /// Takes the old dir's instance lock (kept by the migration until it returns), or reports a running Telltale.
    /// No old dir: nothing to lock (never creates it).
    private static func lockLegacy(_ dir: URL) -> LegacyLock {
        guard FileManager.default.fileExists(atPath: dir.path) else { return .acquired(nil) }
        switch InstanceLock.acquire(dataDirectory: dir) {
        case .acquired(let lock): return .acquired(lock)
        case .heldByAnotherInstance: return .heldByTelltale
        case .unavailable: return .acquired(nil)
        }
    }

    /// A new dir left by an earlier Warden launch that couldn't migrate: `.instance.lock` and a `history.sqlite`
    /// (+ -wal/-shm) whose tables hold no rows.
    private static func holdsOnlyAnEmptyStore(_ dir: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        let allowed: Set<String> = [".instance.lock", "history.sqlite", "history.sqlite-wal", "history.sqlite-shm"]
        guard names.allSatisfy(allowed.contains), names.contains("history.sqlite") else { return false }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let path = dir.appendingPathComponent("history.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
        var tables: [String] = []
        guard each(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
                   { tables.append(String(cString: sqlite3_column_text($0, 0))) }) else { return false }
        for t in tables {
            var rows = 1
            let quoted = t.replacingOccurrences(of: "\"", with: "\"\"")
            guard each(db, "SELECT EXISTS(SELECT 1 FROM \"\(quoted)\")", { rows = Int(sqlite3_column_int($0, 0)) }),
                  rows == 0 else { return false }
        }
        return true
    }

    private static func each(_ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: row(stmt)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }
}
