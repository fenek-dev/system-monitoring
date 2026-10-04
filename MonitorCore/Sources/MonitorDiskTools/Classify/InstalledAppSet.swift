import Foundation
import MonitorModel

/// Bundle IDs of installed apps and their nested bundles (spec §6.2). Built once per scan; never `lsregister -dump`.
public struct InstalledAppSet: Sendable {
    /// Lowercased installed ID → owning app. Nested bundles (helpers, extensions) map to their host app.
    private let apps: [String: OwnerApp]
    /// Every dot-boundary prefix / suffix of an installed ID with ≥ 2 components, for the reverse containment check.
    private let affixes: Set<String>
    private let vendors: Set<String>

    /// `ids` keys may be in any case.
    public init(ids: [String: OwnerApp]) {
        var apps: [String: OwnerApp] = [:]
        var affixes: Set<String> = []
        var vendors: Set<String> = []
        for (id, app) in ids {
            let lowered = id.lowercased()
            apps[lowered] = app
            let parts = lowered.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2 else { continue }
            vendors.insert(parts[0 ..< 2].joined(separator: "."))
            for k in 1 ..< parts.count {
                affixes.insert(parts[..<k].joined(separator: "."))
                affixes.insert(parts[k...].joined(separator: "."))
            }
        }
        self.apps = apps
        self.affixes = affixes
        self.vendors = vendors
    }

    public func owns(_ normalized: String) -> Bool {
        match(normalized) != nil
    }

    public func app(for normalized: String) -> OwnerApp? {
        match(normalized).flatMap { apps[$0] }
    }

    /// Installed ID that owns `normalized`: equal, a dot-boundary prefix or suffix of it, or vice versa, or the same
    /// vendor (first two components, both IDs with ≥ 2). Nearest relation wins so a cache maps to its own app.
    private func match(_ normalized: String) -> String? {
        if apps[normalized] != nil { return normalized }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        // Installed ID is a prefix/suffix of the candidate: longest first.
        for k in stride(from: parts.count - 1, through: 1, by: -1) {
            let prefix = parts[..<k].joined(separator: ".")
            if apps[prefix] != nil { return prefix }
            let suffix = parts[(parts.count - k)...].joined(separator: ".")
            if apps[suffix] != nil { return suffix }
        }
        // Candidate is a prefix/suffix of an installed ID.
        if affixes.contains(normalized) {
            return apps.keys.sorted().first { id in
                id.hasPrefix(normalized + ".") || id.hasSuffix("." + normalized)
            }
        }
        let vendor = parts[0 ..< 2].joined(separator: ".")
        if vendors.contains(vendor) {
            return apps.keys.sorted().first { id in
                let p = id.split(separator: ".", omittingEmptySubsequences: false)
                return p.count >= 2 && p[0 ..< 2].joined(separator: ".") == vendor
            }
        }
        return nil
    }

    // MARK: - Build

    /// `mdfind` is injected: live passes `liveMdfind`, tests a canned list.
    public static func build(home: String, mdfind: @Sendable () throws -> [String]) -> InstalledAppSet {
        var paths: Set<String> = []
        do {
            paths.formUnion(try mdfind())
        } catch {
            // The directory walks below still find most apps; a missing Spotlight hit only risks a later
            // `appPaths` resolution round, which fails safe (owned) rather than offering data.
            DiskTools.log.error("installed apps: mdfind failed: \(String(describing: error), privacy: .public)")
        }
        for root in ["/Applications", home + "/Applications"] {
            paths.formUnion(bundles(under: root, levels: 2))
        }
        paths.formUnion(bundles(under: home + "/Library/Application Support/Steam/steamapps/common", levels: 2))

        var ids: [String: OwnerApp] = [:]
        for path in paths.sorted() where isInstalledLocation(path) {
            let info = readInfo(bundlePath: path)
            var host: OwnerApp?
            if let id = info?.id {
                let owner = OwnerApp(bundleID: id, name: info?.name ?? displayName(path), appPath: path)
                host = owner
                if ids[id.lowercased()] == nil { ids[id.lowercased()] = owner }
            }
            // Nested bundles count even when the outer plist has no ID (iOS wrappers, odd packaging): then each
            // is its own app, otherwise it maps to the host.
            for nested in nestedBundlePaths(path) {
                guard let nestedInfo = readInfo(bundlePath: nested), let nestedID = nestedInfo.id,
                      ids[nestedID.lowercased()] == nil else { continue }
                ids[nestedID.lowercased()] = host ?? OwnerApp(
                    bundleID: nestedID, name: nestedInfo.name ?? displayName(nested), appPath: path)
            }
        }
        return InstalledAppSet(ids: ids)
    }

    /// `mdfind "kMDItemContentType == com.apple.application-bundle"`, ~0.1 s.
    public static let liveMdfind: @Sendable () throws -> [String] = mdfind(run: { executable, arguments in
        try ProcessRun.run(executable, arguments, timeout: 15)
    })

    /// `run` is the process boundary: tests record the arguments instead of spawning.
    static func mdfind(
        run: @escaping @Sendable (_ executable: String, _ arguments: [String]) throws -> ProcessRun.Output
    ) -> @Sendable () throws -> [String] {
        {
            // `-0`: paths may contain newlines.
            let out = try run("/usr/bin/mdfind", ["-0", "kMDItemContentType == com.apple.application-bundle"])
            guard out.status == 0 else { throw ProcessRunError.launchFailed("mdfind exited \(out.status)") }
            return parseNulSeparated(out.stdout)
        }
    }

    static func parseNulSeparated(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Trash, mounted volumes and App Translocation copies are not installs.
    static func isInstalledLocation(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        if components.first == "Volumes" { return false }
        return !components.contains { $0 == ".Trash" || $0 == "AppTranslocation" }
    }

    private static func displayName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// `.app` bundles at most `levels` directories below `root` (`/Applications/Setapp/X.app` is level 2).
    private static func bundles(under root: String, levels: Int) -> [String] {
        let fm = FileManager.default
        // An absent directory (no ~/Applications, no Steam) is the normal case, not a failure.
        guard let children = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var found: [String] = []
        for child in children.sorted() {
            let path = root + "/" + child
            if child.hasSuffix(".app") {
                found.append(path)
            } else if levels > 1 {
                found.append(contentsOf: bundles(under: path, levels: levels - 1))
            }
        }
        return found
    }

    private struct Info {
        var id: String?
        var name: String?
    }

    /// macOS apps keep `Contents/Info.plist`; iOS apps on Apple silicon keep a flat `Info.plist`.
    private static func readInfo(bundlePath: String) -> Info? {
        for plist in [bundlePath + "/Contents/Info.plist", bundlePath + "/Info.plist"] {
            guard let data = FileManager.default.contents(atPath: plist) else { continue }
            guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            else {
                DiskTools.log.debug("installed apps: unreadable Info.plist at \(plist, privacy: .public)")
                return nil
            }
            return Info(id: dict["CFBundleIdentifier"] as? String,
                        name: (dict["CFBundleDisplayName"] as? String) ?? (dict["CFBundleName"] as? String))
        }
        return nil
    }

    private static func nestedBundlePaths(_ appPath: String) -> [String] {
        let fm = FileManager.default
        var nested: [String] = []
        for (sub, suffix) in [("/Contents/Library/LoginItems", ".app"), ("/Contents/Helpers", ".app"),
                              ("/Contents/PlugIns", ".appex"), ("/Wrapper", ".app")] {
            let dir = appPath + sub
            guard let children = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            nested.append(contentsOf: children.sorted().filter { $0.hasSuffix(suffix) }.map { dir + "/" + $0 })
        }
        return nested
    }
}
