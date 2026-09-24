import Foundation

/// One-time move from the app's old identity (Telltale, `dev.telltale.Telltale`) to Warden (`dev.warden.Warden`),
/// run at launch before the single-instance lock, the settings store and the history store open:
/// 1. the data directory moves to its new name (one `rename`, atomic on the same volume) when the new one doesn't
///    exist yet;
/// 2. each old `UserDefaults` domain (the app domain, and the per-data-dir suite in dev) is copied into its new
///    domain when that one is still empty;
/// 3. if the old app was a login item and the new one isn't, the new one registers (the old registration can
///    only be removed from the old bundle: `scripts/install.sh` does that with the old binary's `--login-item`);
/// 4. `doneKey` in `marker` records completion, so later launches do nothing.
/// While a Telltale instance still holds the old data dir, nothing is touched and the next launch retries.
public struct LegacyMigration {
    /// A defaults domain: where to write, and what is persisted in it (not the global/registration layers).
    public struct Domain {
        public var defaults: UserDefaults
        public var persisted: () -> [String: Any]

        public init(defaults: UserDefaults, persisted: @escaping () -> [String: Any]) {
            self.defaults = defaults
            self.persisted = persisted
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
    public static let legacyBundleID = "dev.telltale.Telltale"

    public var legacyDataDirectory: URL?
    public var dataDirectory: URL?
    public var defaults: [(from: Domain, to: Domain)]
    public var marker: UserDefaults
    public var legacyInstanceRunning: () -> Bool
    public var legacyLoginItemEnabled: () -> Bool
    public var loginItemEnabled: () -> Bool
    public var enableLoginItem: () throws -> Void

    public init(legacyDataDirectory: URL?, dataDirectory: URL?, defaults: [(from: Domain, to: Domain)],
                marker: UserDefaults, legacyInstanceRunning: @escaping () -> Bool,
                legacyLoginItemEnabled: @escaping () -> Bool, loginItemEnabled: @escaping () -> Bool,
                enableLoginItem: @escaping () throws -> Void) {
        self.legacyDataDirectory = legacyDataDirectory
        self.dataDirectory = dataDirectory
        self.defaults = defaults
        self.marker = marker
        self.legacyInstanceRunning = legacyInstanceRunning
        self.legacyLoginItemEnabled = legacyLoginItemEnabled
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
            out.data = moveData(from: old, to: new, fm)
        }
        for pair in defaults {
            let old = pair.from.persisted()
            guard !old.isEmpty, pair.to.persisted().keys.allSatisfy({ $0 == Self.doneKey }) else { continue }
            for (key, value) in old { pair.to.defaults.set(value, forKey: key) }
            out.copiedKeys += old.count
        }
        if legacyLoginItemEnabled() && !loginItemEnabled() {
            out.loginItemRegistered = (try? enableLoginItem()) != nil
        }
        marker.set(true, forKey: Self.doneKey)
        out.completed = true
        return out
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
