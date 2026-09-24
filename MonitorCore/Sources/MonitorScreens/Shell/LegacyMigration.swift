import Foundation

/// One-time move from the app's old identity (Telltale, `dev.telltale.Telltale`) to Warden (`dev.warden.Warden`),
/// run at launch before the single-instance lock, the settings store and the history store open:
/// 1. the data directory moves to its new name (one `rename`, atomic on the same volume) when the new one doesn't
///    exist yet; if the move fails, nothing else happens and the next launch retries;
/// 2. each old `UserDefaults` domain (the app domain, and the per-data-dir suite in dev) is merged into its new
///    domain when that one is still empty, written in one pass (`setPersistentDomain`);
/// 3. launch at login: only if the old app's migrated defaults record it (`legacyLoginItem`) and it was on, the
///    new app registers. Telltale never persisted it (it read `SMAppService` only), so in practice nothing happens.
///    The old registration can't be removed from the new bundle, and the old binary is never run: the user is told
///    once (`noticePendingKey`, "Warden replaced Telltale…") to remove it and delete Telltale.app;
/// 4. `doneKey` in `marker` records completion, so later launches do nothing.
/// While a Telltale instance still holds the old data dir, nothing is touched and the next launch retries.
public struct LegacyMigration {
    /// A defaults domain: what is persisted in it (not the global/registration layers), and a one-pass replace.
    public struct Domain {
        public var persisted: () -> [String: Any]
        public var replace: ([String: Any]) -> Void

        public init(persisted: @escaping () -> [String: Any], replace: @escaping ([String: Any]) -> Void) {
            self.persisted = persisted
            self.replace = replace
        }
    }

    public enum DataOutcome: Equatable, Sendable {
        case moved, noLegacyData, newAlreadyExists, legacyInUse
        case failed(String)
    }

    public struct Outcome: Equatable, Sendable {
        public var alreadyDone = false
        /// Nil when no data dir is migrated (dev data dirs keep their path) or the migration already ran.
        public var data: DataOutcome?
        public var copiedKeys = 0
        public var loginItemRegistered = false
        /// The marker was written (false: already done, or deferred to the next launch).
        public var completed = false
    }

    public static let doneKey = "migration.fromTelltale.done"
    /// Set in `marker` when something was migrated; `takeNotice` reads and clears it (shown once).
    public static let noticePendingKey = "migration.fromTelltale.noticePending"
    public static let noticeText =
        "Warden replaced Telltale. Remove Telltale from System Settings › General › Login Items and delete Telltale.app."
    public static let legacyBundleID = "dev.telltale.Telltale"

    public var legacyDataDirectory: URL?
    public var dataDirectory: URL?
    /// The first pair is the app's main domain (its old contents feed `legacyLoginItem`).
    public var defaults: [(from: Domain, to: Domain)]
    public var marker: UserDefaults
    public var legacyInstanceRunning: () -> Bool
    /// Launch-at-login as recorded in the old main domain; nil = not recorded (do nothing).
    public var legacyLoginItem: ([String: Any]) -> Bool?
    public var loginItemEnabled: () -> Bool
    public var enableLoginItem: () throws -> Void

    public init(legacyDataDirectory: URL?, dataDirectory: URL?, defaults: [(from: Domain, to: Domain)],
                marker: UserDefaults, legacyInstanceRunning: @escaping () -> Bool,
                legacyLoginItem: @escaping ([String: Any]) -> Bool? = { _ in nil },
                loginItemEnabled: @escaping () -> Bool = { true }, enableLoginItem: @escaping () throws -> Void = {}) {
        self.legacyDataDirectory = legacyDataDirectory
        self.dataDirectory = dataDirectory
        self.defaults = defaults
        self.marker = marker
        self.legacyInstanceRunning = legacyInstanceRunning
        self.legacyLoginItem = legacyLoginItem
        self.loginItemEnabled = loginItemEnabled
        self.enableLoginItem = enableLoginItem
    }

    public func run(fileManager fm: FileManager = .default) -> Outcome {
        var out = Outcome()
        if marker.bool(forKey: Self.doneKey) {
            out.alreadyDone = true
            return out
        }
        if legacyInstanceRunning() {
            out.data = .legacyInUse
            return out
        }
        if let old = legacyDataDirectory, let new = dataDirectory {
            let data = moveData(from: old, to: new, fm)
            out.data = data
            if case .failed = data { return out }                   // retry next launch; settings stay with the data
        }
        let own: Set<String> = [Self.doneKey, Self.noticePendingKey]
        var mainLegacy: [String: Any] = [:]
        for (i, pair) in defaults.enumerated() {
            let old = pair.from.persisted()
            if i == 0 { mainLegacy = old }
            let current = pair.to.persisted()
            guard !old.isEmpty, current.keys.allSatisfy(own.contains) else { continue }
            pair.to.replace(current.merging(old) { mine, _ in mine })
            out.copiedKeys += old.count
        }
        if legacyLoginItem(mainLegacy) == true && !loginItemEnabled() {
            out.loginItemRegistered = (try? enableLoginItem()) != nil
        }
        if out.data == .moved || out.copiedKeys > 0 { marker.set(true, forKey: Self.noticePendingKey) }
        marker.set(true, forKey: Self.doneKey)
        out.completed = true
        return out
    }

    /// True once after a migration that moved something (the App shows `noticeText`), then false.
    public static func takeNotice(_ marker: UserDefaults) -> Bool {
        guard marker.bool(forKey: noticePendingKey) else { return false }
        marker.removeObject(forKey: noticePendingKey)
        return true
    }

    private func moveData(from old: URL, to new: URL, _ fm: FileManager) -> DataOutcome {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return .noLegacyData }
        guard !fm.fileExists(atPath: new.path) else { return .newAlreadyExists }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            return .moved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
