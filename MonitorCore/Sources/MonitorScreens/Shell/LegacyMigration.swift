import Foundation

/// One-time move from the app's old identity (Telltale, `dev.telltale.Telltale`) to Warden (`dev.warden.Warden`),
/// run at launch before the single-instance lock, the settings store and the history store open:
/// 1. the data directory moves to its new name (one `rename`, atomic on the same volume) when the new one doesn't
///    exist yet or holds nothing worth keeping (`newDataIsDisposable`); the old dir's instance lock is held
///    throughout; if the move fails, nothing else happens and the next launch retries;
/// 2. each old `UserDefaults` domain (the app domain, and the per-data-dir suite in dev) is merged into its new
///    domain when that one is still empty, written in one pass (`setPersistentDomain`);
/// 3. launch at login: only if the old app's migrated defaults record it (`legacyLoginItem`) and it was on, the
///    new app registers. Telltale never persisted it (it read `SMAppService` only), so in practice nothing happens.
///    The old registration can't be removed from the new bundle, and the old binary is never run: the user is told
///    once (`noticePendingKey`, "Warden replaced Telltale…") to remove it and delete Telltale.app, with an
///    "Open at Login" choice for Warden;
/// 4. `doneKey` in `marker` records completion, so later launches do nothing.
/// While a Telltale instance holds the old data dir (`.legacyInUse`), nothing is touched; the App says
/// `legacyRunningText` and exits before creating anything, and the next launch migrates.
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
    public static let noticeTextWithoutLogin =
        "Warden replaced Telltale. Remove Telltale from System Settings › General › Login Items and delete Telltale.app."
    /// With the "Open at Login" button (installed copy, not yet a login item).
    public static let noticeText = noticeTextWithoutLogin + " To start Warden when you log in, choose Open at Login."
    public static let noticeLoginButton = "Open at Login"
    /// `.legacyInUse`: the App shows this and exits before creating anything of its own.
    public static let legacyRunningText = "Telltale is running. Quit Telltale, then open Warden."
    public static let legacyBundleID = "dev.telltale.Telltale"

    public var legacyDataDirectory: URL?
    public var dataDirectory: URL?
    /// The first pair is the app's main domain (its old contents feed `legacyLoginItem`).
    public var defaults: [(from: Domain, to: Domain)]
    public var marker: UserDefaults
    /// Takes the old data dir's instance lock (`.acquired(token)`, the token is held until the migration returns,
    /// so no Telltale can start on the old dir mid-move) or reports a running Telltale (`.heldByTelltale`).
    public var lockLegacy: () -> LegacyLock
    /// True when an existing new data dir holds nothing worth keeping (a lock file, an empty store left by a launch
    /// that couldn't migrate): it is removed and the old dir moved in. Default: only `.instance.lock` and
    /// zero-length files.
    public var newDataIsDisposable: (URL) -> Bool
    /// Launch-at-login as recorded in the old main domain; nil = not recorded (do nothing).
    public var legacyLoginItem: ([String: Any]) -> Bool?
    public var loginItemEnabled: () -> Bool
    public var enableLoginItem: () throws -> Void

    public init(legacyDataDirectory: URL?, dataDirectory: URL?, defaults: [(from: Domain, to: Domain)],
                marker: UserDefaults, lockLegacy: @escaping () -> LegacyLock = { .acquired(nil) },
                newDataIsDisposable: @escaping (URL) -> Bool = LegacyMigration.onlyLockOrEmptyFiles,
                legacyLoginItem: @escaping ([String: Any]) -> Bool? = { _ in nil },
                loginItemEnabled: @escaping () -> Bool = { true }, enableLoginItem: @escaping () throws -> Void = {}) {
        self.legacyDataDirectory = legacyDataDirectory
        self.dataDirectory = dataDirectory
        self.defaults = defaults
        self.marker = marker
        self.lockLegacy = lockLegacy
        self.newDataIsDisposable = newDataIsDisposable
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
        let token: AnyObject?
        switch lockLegacy() {
        case .heldByTelltale:
            out.data = .legacyInUse                                  // the App tells the user and exits
            return out
        case .acquired(let t):
            token = t
        }
        defer { withExtendedLifetime(token) {} }                    // lock held through the move and the copy
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
        do {
            if fm.fileExists(atPath: new.path) {
                guard newDataIsDisposable(new) else { return .newAlreadyExists }
                try fm.removeItem(at: new)
            }
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            return .moved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Default `newDataIsDisposable`: a directory holding only `.instance.lock` and zero-length files.
    public static func onlyLockOrEmptyFiles(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
        else { return false }
        return items.allSatisfy { url in
            if url.lastPathComponent == ".instance.lock" { return true }
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]), v.isDirectory != true
            else { return false }
            return (v.fileSize ?? 1) == 0
        }
    }
}

/// `LegacyMigration.lockLegacy` result.
public enum LegacyLock {
    /// The old dir's lock is ours (token: the lock object, nil when there is no old dir); keep it until done.
    case acquired(AnyObject?)
    /// A running Telltale holds it.
    case heldByTelltale
}
