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

/// Grouping by responsible PID (§5.1, ruling 2026-09-24):
/// 1. `r = responsible ?? process`; path of `r` (nil if EPERM — never the child's path).
/// 2. Path contains `.app/` → outermost `.app` → `AppKey(.app, bundleID ?? bundlePath)`,
///    name `CFBundleDisplayName ?? CFBundleName ?? filename`.
/// 3. Else, any uid → `AppKey(.process, path ?? p_comm)`, named by the executable name.
/// 4. No path and no name → `.system`.
/// Identities depend on `r` only and are cached per `ProcessID` of `r`; bundle info is cached per bundle path
/// (disk read once) while a cached process still references it.
public final class BundleAppResolver: AppResolving {
    private struct BundleInfo {
        var key: AppKey
        var displayName: String
    }

    /// Kept for the locked signature; grouping no longer depends on the uid (ruling 2026-09-24).
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
    var cachedBundleCount: Int { byBundle.count }

    public func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity {
        let r = responsible ?? process
        if let hit = byProcess[r.id] { return hit }
        let id = resolve(r)
        byProcess[r.id] = id
        return id
    }

    /// Drops identities of dead processes and bundle info no remaining identity references.
    public func prune(keeping live: Set<ProcessID>) {
        let dead = byProcess.keys.filter { !live.contains($0) }
        guard !dead.isEmpty else { return }
        for key in dead { byProcess[key] = nil }
        let referenced = Set(byProcess.values.compactMap(\.bundlePath))
        for path in byBundle.keys.filter({ !referenced.contains($0) }) { byBundle[path] = nil }
    }

    // MARK: - Rules

    private func resolve(_ r: RawProcess) -> AppIdentity {
        if let path = r.path, let bundlePath = Self.outermostBundle(in: path) {
            let info = bundleInfo(bundlePath)
            return AppIdentity(key: info.key, displayName: info.displayName, bundlePath: bundlePath)
        }
        if let path = r.path, !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            return AppIdentity(key: AppKey(kind: .process, id: path), displayName: name.isEmpty ? r.comm : name)
        }
        if !r.comm.isEmpty {
            return AppIdentity(key: AppKey(kind: .process, id: r.comm), displayName: r.comm)
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
