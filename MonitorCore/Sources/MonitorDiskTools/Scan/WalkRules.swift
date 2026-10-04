import Foundation
import MonitorModel

/// Marker files recognised by raw name compare in a directory's own listing (spec §5.3). No syscalls: the names
/// are already in the listing buffer.
struct MarkerTable: Sendable {
    static let standard = MarkerTable([
        (".git", .git), ("package.json", .packageJSON), ("Package.swift", .packageSwift),
        ("Cargo.toml", .cargoToml), ("Podfile", .podfile), ("build.gradle", .gradle),
        ("build.gradle.kts", .gradle), ("settings.gradle", .gradle), ("settings.gradle.kts", .gradle),
        ("CMakeLists.txt", .cmakeLists), ("CACHEDIR.TAG", .cachedirTag), ("CMakeCache.txt", .cmakeCache),
        ("workspace-state.json", .swiftpmWorkspaceState), (".package-lock.json", .npmLock),
        (".modules.yaml", .pnpmModules), (".yarn-state.yml", .yarnState), ("Manifest.lock", .podsManifest),
    ])

    private let table: [[UInt8]: StorageMarker]
    private let lengths: ClosedRange<Int>

    init(_ pairs: [(String, StorageMarker)]) {
        var table: [[UInt8]: StorageMarker] = [:]
        for (name, marker) in pairs { table[Array(name.utf8), default: []].formUnion(marker) }
        self.table = table
        let sizes = table.keys.map(\.count)
        lengths = (sizes.min() ?? 0) ... (sizes.max() ?? 0)
    }

    func marker(for name: [UInt8]) -> StorageMarker? {
        // Most names are outside the marker lengths; skip hashing them.
        guard lengths.contains(name.count) else { return nil }
        return table[name]
    }
}

/// Name-based walk decisions (spec §5.2 / §5.3), all on raw name bytes.
struct WalkRules: Sendable {
    static let packageExtensions: Set<[UInt8]> = Set([
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "fcpbundle", "xcarchive", "pvm", "utm", "framework",
        "bundle", "plugin", "appex", "kext", "prefpane", "xpc", "sparsebundle", "vmwarevm", "imovielibrary",
        "theater", "logicx", "band", "rtfd", "xcodeproj", "xcworkspace", "playground", "scptd", "qlgenerator",
        "mdimporter", "component", "saver", "wdgt", "docset", "dsym",
    ].map { Array($0.lowercased().utf8) })

    static let skippedSystemDirs: Set<[UInt8]> = Set(
        [".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100"].map { Array($0.utf8) })

    static let buildDirNames: Set<[UInt8]> = Set(
        ["node_modules", ".build", "target", "Pods", "build"].map { Array($0.utf8) })
    private static let cmakeBuildPrefix = Array("cmake-build-".utf8)

    /// `~/Library` subdirectories whose direct children are all kept as nodes (classifier input, incl. small plists).
    static let libraryKeepDirs = ["Application Support", "Caches", "Containers", "Group Containers", "Preferences",
                                  "Saved Application State", "HTTPStorages", "WebKit", "Logs"]

    /// Files at least this large get their own node (decimal MB, DESIGN §5.3 storage units).
    static let keptFileThreshold: UInt64 = 1_000_000

    let markers: MarkerTable
    /// What a directory's own location means for its children.
    struct Role: Sendable {
        /// Direct children are all kept as nodes (a `~/Library` subfolder the classifier reads).
        var keepAllChildren = false
    }

    /// Locations (relative to home) whose first open raises a macOS consent prompt or is sensitive category data
    /// (Mail, Messages, Safari, Calendars…). `restrict`: never opened without Full Disk Access. `prompt`: one-time,
    /// user-meaningful consents (Desktop, Documents, iCloud…), opened only when prompts are allowed.
    private static let restrictedRules: [[String]] = [
        ["Library", "Calendars"], ["Library", "Application Support", "AddressBook"], ["Library", "Reminders"],
        ["Library", "Group Containers", "group.com.apple.reminders"], ["Library", "Mail"], ["Library", "Messages"],
        ["Library", "Safari"],
        // The package's size is unknown rather than 0: a restricted leaf.
        ["Pictures", "Photos Library.photoslibrary"],
    ]
    private static let promptRules: [[String]] = [
        ["Desktop"], ["Documents"], ["Downloads"], ["Library", "Mobile Documents"], ["Library", "CloudStorage"],
    ]

    /// Scan root and home, normalized the same way, as component lists.
    private let rootParts: [String]
    private let homeParts: [String]
    private var homeLibrary: [String] { homeParts + ["Library"] }
    /// Deepest absolute path length a rule can match by equality: deeper entries need no rule lookup.
    private let maxRuleDepth: Int

    init(root: ScanRoot, home: String, markers: MarkerTable = .standard) {
        self.markers = markers
        rootParts = Self.normalized(root.path)
        homeParts = Self.normalized(home)
        maxRuleDepth = max(homeParts.count + 3, 2)
    }

    /// True when an entry at this depth below the root could fall under an access rule (cheap pre-test).
    func mayBeGuarded(depth components: Int) -> Bool { rootParts.count + components <= maxRuleDepth }

    /// True if the directory at `components` below the scan root is, or lies inside, a location the policy keeps
    /// closed: it must then be recorded as restricted without being opened. Evaluated before the root is acquired,
    /// before every directory open, and for package traversal. With Full Disk Access nothing is closed (no prompts
    /// exist then); `promptMode == .never` closes the prompt locations too.
    func blocks(_ components: [String], access: ScanAccessPolicy) -> Bool {
        if access.fullDiskAccess { return false }
        let absolute = rootParts + components
        for rule in Self.restrictedRules where absolute.starts(with: homeParts + rule) { return true }
        if access.promptMode == .never {
            for rule in Self.promptRules where absolute.starts(with: homeParts + rule) { return true }
            // A volume the user chose (removable, network): `/Volumes/<name>` and everything on it.
            if absolute.count >= 2, absolute[0] == "Volumes" { return true }
        }
        // Other apps' containers; this app's own are always readable.
        let library = homeLibrary
        if absolute.count > library.count + 1, absolute.starts(with: library),
           absolute[library.count] == "Containers" || absolute[library.count] == "Group Containers",
           !access.isOwnContainer(absolute[library.count + 1]) {
            return true
        }
        return false
    }

    /// Role of the directory at `components` below the scan root. Resolved from absolute locations, so a root
    /// inside `~/Library`, or spelled through the `/System/Volumes/Data` alias, behaves like the home scan.
    func role(of components: [String]) -> Role {
        let library = homeLibrary
        guard rootParts.count + components.count == library.count + 1 else { return Role() }
        let absolute = rootParts + components
        guard absolute.starts(with: library) else { return Role() }
        return Role(keepAllChildren: Self.libraryKeepDirs.contains(absolute[library.count]))
    }

    /// Symlinks resolved when the path exists; the Data volume's firmlink prefix dropped, so `/Users/x` and
    /// `/System/Volumes/Data/Users/x` compare equal.
    private static func normalized(_ path: String) -> [String] {
        var resolved = path
        if let real = Darwin.realpath(path, nil) {
            resolved = String(cString: real)
            free(real)
        }
        var parts = resolved.split(separator: "/").map(String.init)
        if parts.starts(with: ["System", "Volumes", "Data"]) { parts.removeFirst(3) }
        return parts
    }

    static func isPackage(_ name: [UInt8]) -> Bool {
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > name.startIndex else { return false }
        let ext = name[(dot + 1)...].map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        return packageExtensions.contains(ext)
    }

    static func isBuildDir(_ name: [UInt8]) -> Bool {
        buildDirNames.contains(name) || name.starts(with: cmakeBuildPrefix)
    }

    static func isHidden(_ name: [UInt8], fileFlags: UInt32) -> Bool {
        name.first == UInt8(ascii: ".") || fileFlags & UInt32(UF_HIDDEN) != 0
    }
}
