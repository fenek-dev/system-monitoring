import AppKit
import MonitorScreens
import os
import ServiceManagement

/// App side of `LegacyMigration` (Telltale → Warden): real directories, defaults domains and login items.
/// Runs first thing at launch, before the instance lock and the stores.
@MainActor
enum LegacyMigrationRunner {
    private static let log = Logger(subsystem: "dev.telltale", category: "Migration")

    static func run(_ options: LaunchOptions) {
        let migration = options.dataDirectory.map(devMigration) ?? productionMigration()
        guard let migration else { return }
        let out = migration.run()
        guard !out.alreadyDone else { return }
        log.notice("""
            legacy migration completed=\(out.completed) data=\(String(describing: out.data), privacy: .public) \
            keys=\(out.copiedKeys) loginItem=\(out.loginItemRegistered)
            """)
    }

    /// Installed app: `~/Library/Application Support/dev.telltale` → `dev.warden`, domain `dev.telltale.Telltale`
    /// → this bundle's domain, login item.
    private static func productionMigration() -> LegacyMigration? {
        let old = AppEnvironment.legacyDataDirectory()
        let newName = Bundle.main.bundleIdentifier ?? "dev.warden.Warden"
        let oldName = LegacyMigration.legacyBundleID
        guard newName != oldName, let oldDefaults = UserDefaults(suiteName: oldName) else { return nil }
        return LegacyMigration(
            legacyDataDirectory: old, dataDirectory: AppEnvironment.defaultDataDirectory(),
            defaults: [(from: domain(oldDefaults, oldName), to: domain(.standard, newName))],
            marker: .standard,
            legacyInstanceRunning: { legacyInstanceHolds(old) },
            legacyLoginItemEnabled: { LaunchAtLogin.isStablePath && legacyLoginItemEnabled() },
            loginItemEnabled: { SMAppService.mainApp.status == .enabled },
            enableLoginItem: { try LaunchAtLogin.setEnabled(true) })
    }

    /// Worktree builds (`TELLTALE_DATA_DIR`): the data dir keeps its path; only the per-dir suite is renamed.
    private static func devMigration(_ dir: URL) -> LegacyMigration? {
        let oldName = SettingsStore.legacySuiteName(for: dir), newName = SettingsStore.suiteName(for: dir)
        guard let oldSuite = UserDefaults(suiteName: oldName), let newSuite = UserDefaults(suiteName: newName) else {
            return nil
        }
        return LegacyMigration(
            legacyDataDirectory: nil, dataDirectory: nil,
            defaults: [(from: domain(oldSuite, oldName), to: domain(newSuite, newName))], marker: newSuite,
            legacyInstanceRunning: { false }, legacyLoginItemEnabled: { false }, loginItemEnabled: { true },
            enableLoginItem: {})
    }

    private static func domain(_ defaults: UserDefaults, _ name: String) -> LegacyMigration.Domain {
        LegacyMigration.Domain(defaults: defaults,
                               persisted: { UserDefaults.standard.persistentDomain(forName: name) ?? [:] })
    }

    /// A Telltale still running on the old data dir holds its instance lock.
    private static func legacyInstanceHolds(_ dir: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        if case .heldByAnotherInstance = InstanceLock.acquire(dataDirectory: dir) { return true }
        return false
    }

    /// Asks the installed Telltale itself (`--login-item status` prints its `SMAppService.mainApp` status and
    /// exits): only that bundle can read its own registration. Skipped when the binary predates the flag, so an
    /// old build is never started as a full app. 5-s cap.
    private static func legacyLoginItemEnabled() -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: LegacyMigration.legacyBundleID),
              let exe = Bundle(url: app)?.executableURL,
              let binary = try? Data(contentsOf: exe, options: .mappedIfSafe),
              binary.range(of: Data("--login-item".utf8)) != nil
        else { return false }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--login-item", "status"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            return false
        }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        log.notice("legacy login item: \(text.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
        return text.contains("status=enabled")
    }
}
