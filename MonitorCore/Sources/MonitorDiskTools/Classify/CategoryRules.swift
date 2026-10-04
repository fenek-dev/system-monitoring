import Foundation

/// Path and name tables behind the classifier (spec §6.3). Paths are relative to the home directory.
enum CategoryRules {
    /// Children of these are User Caches candidates.
    static let cacheParents = ["Library/Caches", "Library/Logs", ".cache"]
    /// `~/Library/Containers/<id>/Data/Library/Caches`
    static let containersDir = "Library/Containers"
    static let containerCachesSubpath = ["Data", "Library", "Caches"]

    /// Children of these are Leftovers candidates (normalized-ID names).
    static let leftoverParents = [
        "Library/Application Support", "Library/Caches", "Library/Containers", "Library/Group Containers",
        "Library/Preferences", "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit",
    ]

    /// Apple IDs that are plain app caches, not system state.
    static let appleAllowlist: Set<String> = ["com.apple.dt.xcode"]

    /// System caches without a `com.apple.` name: deleting them breaks iCloud, Maps, Wallet, Find My, Home…
    static let systemCacheNames: Set<String> = [
        "CloudKit", "com.apple.bird", "GeoServices", "PassKit", "FamilyCircle", "familycircled", "GameKit",
        "Animoji", "askpermissiond", "TemporaryItems", "nsurlsessiond", "akd", "containermanagerd", "HomeKit",
        "homed", "ap.adprivacyd",
    ]
    static let systemCachePrefixes = ["findmy"]

    static func isSystemCacheName(_ name: String) -> Bool {
        systemCacheNames.contains(name) || systemCachePrefixes.contains { name.lowercased().hasPrefix($0) }
    }

    /// Never an item: our own stores and staging (`App/Sources/Composition/AppEnvironment.swift`, `scripts/run.sh`).
    static let ownDataPrefixes = ["dev.telltale", "dev.warden"]

    static func isOwnDataName(_ nameBytes: ArraySlice<UInt8>) -> Bool {
        ownDataPrefixes.contains { prefix in nameBytes.starts(with: prefix.utf8) }
    }

    // MARK: Developer

    /// Regenerable caches deleted outright (Safe, `.remove`). Each is the tool's default location:
    /// Xcode, Homebrew (`brew --cache`), npm (`npm config get cache` + `_cacache`), Yarn classic (`yarn cache dir`),
    /// pnpm (`pnpm store path` and its metadata cache), pip (`pip cache dir`), Cargo (`$CARGO_HOME/registry`),
    /// Gradle, CocoaPods, JetBrains IDEs.
    static let developerSafePaths: [(path: String, label: String)] = [
        ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData"),
        ("Library/Caches/Homebrew", "Homebrew cache"),
        (".npm/_cacache", "npm cache"),
        ("Library/Caches/Yarn", "Yarn cache"),
        ("Library/pnpm/store", "pnpm store"),
        ("Library/Caches/pnpm", "pnpm cache"),
        ("Library/Caches/pip", "pip cache"),
        (".cargo/registry/cache", "Cargo registry cache"),
        (".cargo/registry/src", "Cargo registry sources"),
        (".gradle/caches", "Gradle cache"),
        ("Library/Caches/CocoaPods", "CocoaPods cache"),
        ("Library/Caches/JetBrains", "JetBrains caches"),
    ]

    /// Per-platform support files, one dir per OS version / device: all but the newest are offered.
    static let deviceSupportDirs = [
        "Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
        "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport",
    ]

    static let archivesDir = "Library/Developer/Xcode/Archives"
    static let archivesAge: TimeInterval = 180 * 86400

    static let simulatorDevicesDir = "Library/Developer/CoreSimulator/Devices"

    /// Docker Desktop's disk image (legacy and current locations); info only.
    static let dockerImages = [
        "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
        ".docker/desktop/vms/0/data/Docker.raw",
    ]
    static let dockerNote = "Docker disk image; never deleted here. Run `docker system prune` to reclaim space."

    static let leftoverAge: TimeInterval = 90 * 86400
}
