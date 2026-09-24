import Foundation
import MonitorModel

/// Maps a process to its app (ARCHITECTURE §5.1). Owned by the engine actor; not Sendable.
public protocol AppResolving: AnyObject {
    func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity
    func prune(keeping live: Set<ProcessID>)
}

extension AppIdentity {
    static let system = AppIdentity(key: .system, displayName: "System")
    static let other = AppIdentity(key: .other, displayName: "Other")
}

/// Grouping by responsible PID (§5.1):
/// 1. `r = responsible ?? process`; path of `r` (falls back to the process's own path when `r`'s is unreadable).
/// 2. Path contains `.app/` → outermost `.app` → `AppKey(.app, bundleID ?? bundlePath)`,
///    name `CFBundleDisplayName ?? CFBundleName ?? filename`.
/// 3. Else owned by the current uid and not under a system prefix → `AppKey(.process, path ?? p_comm)`.
/// 4. Else → `.system`.
/// Identities are cached per `ProcessID` of `r`; bundle info is cached per bundle path (disk read once).
public final class BundleAppResolver: AppResolving {
    static let systemPrefixes = ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"]

    private struct BundleInfo {
        var key: AppKey
        var displayName: String
    }

    private let currentUID: uid_t
    private let readInfoPlist: (String) -> [String: Any]?
    private var byProcess: [ProcessID: AppIdentity] = [:]
    private var byBundle: [String: BundleInfo] = [:]

    public convenience init(currentUID: uid_t = getuid()) {
        self.init(currentUID: currentUID, readInfoPlist: BundleAppResolver.readInfoPlist)
    }

    /// Test seam: `readInfoPlist(bundlePath)` returns the bundle's Info.plist dictionary.
    init(currentUID: uid_t, readInfoPlist: @escaping (String) -> [String: Any]?) {
        self.currentUID = currentUID
        self.readInfoPlist = readInfoPlist
    }

    var cachedProcessCount: Int { byProcess.count }

    public func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity {
        let r = responsible ?? process
        if let hit = byProcess[r.id] { return hit }
        let id = resolve(r, fallbackPath: process.path)
        byProcess[r.id] = id
        return id
    }

    public func prune(keeping live: Set<ProcessID>) {
        for key in byProcess.keys.filter({ !live.contains($0) }) { byProcess[key] = nil }
    }

    // MARK: - Rules

    private func resolve(_ r: RawProcess, fallbackPath: String?) -> AppIdentity {
        let path = r.path ?? fallbackPath
        if let path, let bundlePath = Self.outermostBundle(in: path) {
            let info = bundleInfo(bundlePath)
            return AppIdentity(key: info.key, displayName: info.displayName, bundlePath: bundlePath)
        }
        if r.uid == currentUID, !(path.map(Self.isSystemPath) ?? false) {
            let key = AppKey(kind: .process, id: path ?? r.comm)
            let name = path.map { ($0 as NSString).lastPathComponent } ?? r.comm
            return AppIdentity(key: key, displayName: name.isEmpty ? r.comm : name)
        }
        return .system
    }

    private func bundleInfo(_ bundlePath: String) -> BundleInfo {
        if let hit = byBundle[bundlePath] { return hit }
        let plist = readInfoPlist(bundlePath)
        let fileName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleID = (plist?["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = [plist?["CFBundleDisplayName"], plist?["CFBundleName"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty } ?? fileName
        let info = BundleInfo(key: AppKey(kind: .app, id: bundleID ?? bundlePath), displayName: name)
        byBundle[bundlePath] = info
        return info
    }

    /// `/Applications/Arc.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper` → `/Applications/Arc.app`.
    static func outermostBundle(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<path.index(r.lowerBound, offsetBy: 4)])
    }

    static func isSystemPath(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) }
    }

    /// Reads `<bundle>/Contents/Info.plist` directly (no `Bundle` cache, which would outlive a deleted bundle).
    static func readInfoPlist(_ bundlePath: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

/// Fixed pid → identity map (tests, fixture replay). Looks up the responsible pid, then the pid; else `.system`.
public final class FixtureAppResolver: AppResolving {
    private let map: [Int32: AppIdentity]

    public init(_ map: [Int32: AppIdentity]) {
        self.map = map
    }

    public func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity {
        if let r = responsible, let id = map[r.id.pid] { return id }
        return map[process.id.pid] ?? .system
    }

    public func prune(keeping live: Set<ProcessID>) {}
}
