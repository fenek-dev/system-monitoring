import Foundation
import MonitorModel

/// Deterministic Storage & Cleanup fixtures (spec §8): the five page states W4 renders and snapshots. Fixed dates,
/// sizes, names and ids, seeded hashing only; two `make(k)` calls give equal arrays and an equal `CleanupSet`
/// (tree `version` is a process counter and differs, so `CleanupSet.treeVersion` is the one field that follows it).
public struct MockStorageState: Sendable {
    public enum Kind: String, CaseIterable, Sendable { case empty, scanning, map, cleanup, noFDA }

    public static let home = "/Users/demo"

    public var kind: Kind
    /// nil for `.empty`; a partial snapshot for `.scanning`.
    public var tree: StorageTree?
    public var overlay: StorageTreeOverlay?
    /// nil for `.empty` / `.scanning`.
    public var cleanup: CleanupSet?
    /// `.scanning` only.
    public var progress: ScanProgress?
    /// false for `.noFDA`.
    public var hasFullDiskAccess: Bool
    public var summary: StorageSummary?
    /// Ids `checkInUse` reports.
    public var inUseIDs: Set<Int32>
    public var policy: StoragePolicy

    public static func make(_ kind: Kind, referenceDate: Date = MockDataProvider.referenceDate) -> MockStorageState {
        let now = Int64(referenceDate.timeIntervalSince1970)
        switch kind {
        case .empty:
            return MockStorageState(kind: kind, tree: nil, overlay: nil, cleanup: nil, progress: nil,
                                    hasFullDiskAccess: true, summary: nil, inUseIDs: [], policy: .none)
        case .scanning:
            let tree = Fixture.populate(Fixture.homeSpec(noFDA: false, now: now), now: now, depthLimit: 3).snapshot()
            // Bytes/files are what the scanner would have counted by now, not the partial tree's rolled-up size.
            let progress = ScanProgress(files: 182_340, bytes: 41_700_000_000,
                                        currentPath: "\(home)/Library/Caches/com.google.Chrome/Default/Cache")
            return MockStorageState(kind: kind, tree: tree, overlay: StorageTreeOverlay(tree: tree), cleanup: nil,
                                    progress: progress, hasFullDiskAccess: true, summary: nil, inUseIDs: [],
                                    policy: .none)
        case .map, .cleanup, .noFDA:
            let noFDA = kind == .noFDA
            let scanDate = referenceDate.addingTimeInterval(-2 * 3600)
            let tree = Fixture.populate(Fixture.homeSpec(noFDA: noFDA, now: now), now: now, depthLimit: nil)
                .finalize(scanDate: scanDate, lastEventId: 1)
            let (set, inUse) = Fixture.cleanupSet(tree: tree, now: now)
            let reclaimable = set.items.filter { !$0.ignored && $0.mode != .none }
                .reduce(UInt64(0)) { $0 + ($1.privateBytesExcludingLinks ?? $1.allocBytes) }
            let summary = StorageSummary(root: .home(home), scanDate: scanDate, reclaimableBytes: reclaimable,
                                         provenance: .estimate, trashBytes: set.trashBytes)
            let anchors = Set([tree.lookup(path: home), tree.lookup(path: "\(home)/Library")].compactMap { $0 })
            let protected = Set([tree.lookup(path: "\(home)/Library/Mail")].compactMap { $0 })
            return MockStorageState(
                kind: kind, tree: tree, overlay: StorageTreeOverlay(tree: tree), cleanup: set, progress: nil,
                hasFullDiskAccess: !noFDA, summary: summary, inUseIDs: inUse,
                policy: StoragePolicy(treeVersion: tree.version, anchors: anchors, protected: protected))
        }
    }
}

// MARK: - Fixture

private enum Fixture {
    static let dev: Int32 = 16_777_230
    static let day: Int64 = 86_400
    static let linkIno: UInt64 = 5_000_001
    static let linkBytes: UInt64 = gb(0.038)

    static func gb(_ v: Double) -> UInt64 { UInt64(v * 1_000_000_000) }

    /// Declarative directory tree; `populate` commits it breadth-first so each listing is contiguous.
    struct Spec {
        var name: String
        var flags: StorageNodeFlags = []
        var bytes: UInt64 = 0
        var daysAgo: Int = 30
        var children: [Spec] = []
        var small: (bytes: UInt64, count: UInt32)?
        var markers: StorageMarker = []
        /// Hard-linked file (bytes come from `linkBytes`, credited by `addLink`).
        var isLink = false
    }

    static func file(_ name: String, _ bytes: UInt64, days: Int = 30) -> Spec {
        Spec(name: name, bytes: bytes, daysAgo: days)
    }

    static func dir(_ name: String, flags: StorageNodeFlags = [], days: Int = 30, markers: StorageMarker = [],
                    _ children: [Spec] = []) -> Spec {
        Spec(name: name, flags: flags.union(.directory), daysAgo: days, children: children, markers: markers)
    }

    /// Unreadable dir; the scanner never lists inside it.
    static func locked(_ name: String) -> Spec { dir(name, flags: .restricted) }

    /// `files` skewed-size files named `<stem>-<i>.<ext>` totalling about `total`.
    static func files(_ stem: String, _ ext: String, count: Int, total: UInt64, seed: UInt64, days: Int) -> [Spec] {
        let weights = (0 ..< count).map { pow(SplitMix64.unit(seed, $0), 3) + 0.02 }
        let sum = weights.reduce(0, +)
        return (0 ..< count).map { i in
            file("\(stem)-\(String(format: "%03d", i)).\(ext)", UInt64(Double(total) * weights[i] / sum), days: days)
        }
    }

    /// `dirs` subdirectories of `files` listed files each, plus folded small files taking ~10 % of the bytes.
    static func bulk(total: UInt64, dirs: Int, files fileCount: Int, seed: UInt64, days: Int,
                     names: [String] = []) -> [Spec] {
        let perDir = total / UInt64(dirs)
        return (0 ..< dirs).map { d in
            let name = d < names.count ? names[d] : "part-\(String(format: "%02d", d))"
            var spec = dir(name, days: days, files("item", "dat", count: fileCount, total: perDir * 9 / 10,
                                                   seed: seed &+ UInt64(d), days: days))
            spec.small = (perDir / 10, 240)
            return spec
        }
    }

    static func package(_ name: String, total: UInt64, days: Int) -> Spec {
        dir(name, flags: .package, days: days, [file("Contents.bin", total, days: days)])
    }

    static func homeSpec(noFDA: Bool, now: Int64) -> Spec {
        func guarded(_ name: String, _ children: @autoclosure () -> [Spec], days: Int = 30) -> Spec {
            noFDA ? locked(name) : dir(name, days: days, children())
        }
        func cache(_ name: String, _ total: UInt64, dirs: Int = 6, files: Int = 12, seed: UInt64, days: Int = 3)
            -> Spec {
            dir(name, days: days, bulk(total: total, dirs: dirs, files: files, seed: seed, days: days))
        }
        func nodeModules(_ total: UInt64, seed: UInt64, withLink: Bool) -> Spec {
            var children = bulk(total: total, dirs: 5, files: 10, seed: seed, days: 9,
                                names: ["react", "webpack", "lodash", "@babel", "eslint"])
            if withLink {
                var link = file("swc.darwin-arm64.node", 0, days: 40)
                link.isLink = true
                children.append(dir("@swc", days: 40, [dir("core-darwin-arm64", days: 40, [link])]))
            }
            return dir("node_modules", flags: .buildDir, days: 9, children)
        }
        func project(_ name: String, _ total: UInt64, seed: UInt64, withLink: Bool, days: Int) -> Spec {
            var src = dir("src", days: days, files("module", "ts", count: 14, total: 600_000, seed: seed, days: days))
            src.small = (90_000, 40)
            return dir(name, days: days, markers: [.git, .packageJSON],
                       [nodeModules(total, seed: seed &+ 100, withLink: withLink), src,
                        file("package.json", 3_100, days: days)])
        }

        let library = dir("Library", days: 1, [
            dir("Caches", days: 1, [
                cache("com.spotify.client", gb(4.6), seed: 11, days: 0),
                cache("com.tinyspeck.slackmacgap", gb(1.9), seed: 12),
                cache("com.tinyspeck.slackmacgap.ShipIt", gb(0.64), dirs: 3, seed: 13, days: 20),
                cache("com.google.Chrome", gb(2.3), seed: 14, days: 0),
                cache("Homebrew", gb(3.1), dirs: 5, seed: 15, days: 12),
                cache("com.figma.Desktop", gb(1.2), dirs: 4, seed: 16, days: 6),
                cache("com.apple.iconservices", gb(0.8), dirs: 3, files: 8, seed: 17, days: 1),
            ]),
            dir("Application Support", days: 2, [
                dir("Skype", days: 420, bulk(total: gb(1.4), dirs: 4, files: 10, seed: 21, days: 420)),
                dir("Sketch", days: 300, bulk(total: gb(0.82), dirs: 3, files: 10, seed: 22, days: 300)),
                dir("Code", days: 2, bulk(total: gb(2.2), dirs: 5, files: 10, seed: 23, days: 2,
                                           names: ["User", "CachedData", "logs", "Cache", "WebStorage"])),
                noFDA ? locked("AddressBook") : dir("AddressBook", days: 5, files("card", "abcdp", count: 6,
                                                                                 total: 18_000_000, seed: 24, days: 5)),
            ]),
            guarded("Containers", [
                dir("com.docker.docker", days: 1, bulk(total: gb(14.8), dirs: 4, files: 8, seed: 31, days: 1,
                                                       names: ["Data", "vms", "log", "tmp"])),
            ], days: 1),
            dir("Developer", days: 1, [
                dir("Xcode", days: 1, [
                    dir("DerivedData", days: 2, bulk(total: gb(9.8), dirs: 5, files: 12, seed: 41, days: 2,
                                                     names: ["Warden-bkp", "Pulse-dcz", "Atlas-fqm", "Docs-hjk",
                                                             "Samples-mnb"])),
                    dir("iOS DeviceSupport", days: 60,
                        bulk(total: gb(6.2), dirs: 3, files: 8, seed: 42, days: 60,
                             names: ["iPhone15,2 17.5", "iPhone16,1 18.0", "iPad14,3 17.2"])),
                ]),
                dir("CoreSimulator", days: 45, [
                    dir("Devices", days: 45, bulk(total: gb(5.3), dirs: 3, files: 8, seed: 43, days: 45,
                                                  names: ["3F2A9C10", "8B77D1E4", "C0A41B65"])),
                ]),
            ]),
            dir("Logs", days: 1, bulk(total: gb(0.6), dirs: 2, files: 10, seed: 51, days: 1,
                                      names: ["DiagnosticReports", "CoreSimulator"])),
            dir("Mobile Documents", days: 90, [
                dir("com~apple~CloudDocs", days: 90, [
                    dir("Design Archive", days: 220, bulk(total: gb(3.4), dirs: 3, files: 8, seed: 61, days: 220,
                                                          names: ["2021", "2022", "2023"])),
                ]),
            ]),
            locked("Mail"),
            locked("Messages"),
            guarded("Safari", [dir("LocalStorage", days: 2, files("site", "db", count: 5, total: 90_000_000,
                                                                  seed: 71, days: 2))], days: 1),
            guarded("Group Containers", [dir("group.com.apple.notes", days: 3,
                                              files("note", "db", count: 5, total: 300_000_000, seed: 72, days: 3))],
                    days: 3),
        ])

        return dir("demo", days: 0, [
            dir("Applications", days: 30, [
                package("Docker.app", total: gb(2.1), days: 30),
                package("Slack.app", total: gb(0.4), days: 14),
            ]),
            library,
            dir("Documents", days: 4, [
                dir("Backups", days: 900, [file("old-laptop-2021.dmg", gb(7.8), days: 900)]),
                dir("Work", days: 4, bulk(total: gb(3.2), dirs: 4, files: 8, seed: 81, days: 4,
                                          names: ["Contracts", "Invoices", "Research", "Slides"])),
            ]),
            dir("Downloads", days: 2, [file("ubuntu-24.04-desktop-amd64.iso", gb(6.1), days: 260)]
                + files("download", "pdf", count: 25, total: gb(1.4), seed: 91, days: 12)),
            dir("Movies", days: 3, [
                dir("Wedding 2023 Raw", days: 410, bulk(total: gb(12.4), dirs: 3, files: 8, seed: 101, days: 410,
                                                        names: ["Day 1", "Day 2", "Drone"])),
                dir("Screen Recordings", days: 5, files("recording", "mov", count: 14, total: gb(2.2), seed: 102,
                                                        days: 5)),
            ]),
            dir("Pictures", days: 1, [package("Photos Library.photoslibrary", total: gb(31), days: 1)]),
            dir("Projects", days: 1, [
                project("web-app", gb(1.1), seed: 111, withLink: true, days: 2),
                project("api-server", gb(0.9), seed: 112, withLink: true, days: 11),
                project("dashboard", gb(0.64), seed: 113, withLink: false, days: 8),
            ]),
            dir(".npm", flags: .hidden, days: 6, [
                dir("_cacache", days: 6, bulk(total: gb(1.8), dirs: 4, files: 10, seed: 121, days: 6,
                                              names: ["content-v2", "index-v5", "tmp", "_logs"])),
            ]),
            dir(".Trash", flags: .hidden, days: 8, [
                dir("Old Renders", days: 40, bulk(total: gb(3.9), dirs: 2, files: 8, seed: 131, days: 40,
                                                  names: ["Draft A", "Draft B"])),
            ] + files("Screenshot", "png", count: 22, total: gb(1.8), seed: 132, days: 8)),
        ])
    }

    /// Breadth-first commit; `depthLimit` leaves deeper dirs unlisted, like a scan still in flight.
    static func populate(_ root: Spec, now: Int64, depthLimit: Int?) -> StorageTreeBuilder {
        var builder = StorageTreeBuilder(root: .home(MockStorageState.home), dev: dev,
                                         volumeUUID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0xD1)),
                                         rootFileID: 2, rootMtime: now)
        var queue: [(spec: Spec, node: StorageNodeID, depth: Int)] = [(root, 0, 0)]
        var next = 0
        var fileID: UInt64 = 1_000
        while next < queue.count {
            let (spec, node, depth) = queue[next]
            next += 1
            if spec.flags.contains(.restricted) { builder.setRestricted(node) }
            if !spec.markers.isEmpty { builder.setDirFacts(node, markers: spec.markers, flags: []) }
            if let small = spec.small {
                builder.addSmall(node, bytes: small.bytes, count: small.count,
                                 maxMtime: now - Int64(spec.daysAgo) * day)
            }
            guard !spec.children.isEmpty, depthLimit.map({ depth < $0 }) ?? true else { continue }
            let records = spec.children.map { child -> NodeRecord in
                fileID += 1
                return NodeRecord(name: child.name, flags: child.flags, allocBytes: child.isLink ? 0 : child.bytes,
                                  fileID: child.isLink ? linkIno : fileID, mtime: now - Int64(child.daysAgo) * day,
                                  addedTime: now - Int64(child.daysAgo + 30) * day)
            }
            let range = builder.appendChildren(of: node, records)
            for (i, child) in spec.children.enumerated() {
                let id = range.lowerBound + Int32(i)
                queue.append((child, id, depth + 1))
                if child.isLink {
                    builder.addLink(FileIdentity(dev: dev, ino: linkIno, isDirectory: false), linkCount: 2,
                                    bytes: linkBytes, occurrence: id)
                }
            }
        }
        return builder
    }

    // MARK: Cleanup set

    private struct Def {
        var path: String
        var category: CleanupCategory
        var tier: SafetyTier = .safe
        var mode: DeleteMode = .remove
        var owner: OwnerApp?
        var keepParent = false
        var running = false
        var ignored = false
        var exact = true
        var inUse = false
        var note: String?
        /// Item with no tree node (`simctl` row): size comes from `bytes`.
        var bytes: UInt64?
    }

    private static let spotify = OwnerApp(bundleID: "com.spotify.client", name: "Spotify",
                                          appPath: "/Applications/Spotify.app")
    private static let slack = OwnerApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack",
                                        appPath: "/Applications/Slack.app")
    private static let chrome = OwnerApp(bundleID: "com.google.Chrome", name: "Google Chrome",
                                         appPath: "/Applications/Google Chrome.app")
    private static let figma = OwnerApp(bundleID: "com.figma.Desktop", name: "Figma",
                                        appPath: "/Applications/Figma.app")
    private static let xcode = OwnerApp(bundleID: "com.apple.dt.Xcode", name: "Xcode",
                                        appPath: "/Applications/Xcode.app")
    private static let docker = OwnerApp(bundleID: "com.docker.docker", name: "Docker Desktop",
                                         appPath: "/Applications/Docker.app")
    /// Uninstalled apps: no `appPath`, which is what makes their data leftovers.
    private static let skype = OwnerApp(bundleID: "com.skype.skype", name: "Skype")
    private static let sketch = OwnerApp(bundleID: "com.bohemiancoding.sketch3", name: "Sketch")

    private static func defs() -> [Def] {
        let lib = "Library"
        return [
            Def(path: "\(lib)/Caches/com.spotify.client", category: .userCaches, owner: spotify, keepParent: true,
                running: true),
            Def(path: "\(lib)/Caches/com.tinyspeck.slackmacgap", category: .userCaches, owner: slack,
                keepParent: true),
            Def(path: "\(lib)/Caches/com.tinyspeck.slackmacgap.ShipIt", category: .userCaches, owner: slack,
                keepParent: true, exact: false),
            Def(path: "\(lib)/Caches/com.google.Chrome", category: .userCaches, owner: chrome, keepParent: true,
                inUse: true),
            Def(path: "\(lib)/Caches/Homebrew", category: .userCaches, keepParent: true, exact: false,
                note: "Bottles are re-downloaded on the next install."),
            Def(path: "\(lib)/Caches/com.figma.Desktop", category: .userCaches, owner: figma, keepParent: true,
                ignored: true),
            Def(path: "\(lib)/Application Support/Skype", category: .leftovers, tier: .review, mode: .trash,
                owner: skype),
            Def(path: "\(lib)/Application Support/Sketch", category: .leftovers, tier: .review, mode: .trash,
                owner: sketch, exact: false),
            Def(path: "Movies/Wedding 2023 Raw", category: .largeOld, tier: .review, mode: .trash),
            Def(path: "Downloads/ubuntu-24.04-desktop-amd64.iso", category: .largeOld, tier: .review, mode: .trash),
            Def(path: "Documents/Backups/old-laptop-2021.dmg", category: .largeOld, tier: .review, mode: .trash,
                exact: false),
            Def(path: "\(lib)/Mobile Documents/com~apple~CloudDocs/Design Archive", category: .largeOld,
                tier: .review, mode: .evict, exact: false, note: "Stays in iCloud; only the local copy is removed."),
            Def(path: "\(lib)/Developer/Xcode/DerivedData", category: .developer, owner: xcode, keepParent: true),
            Def(path: "\(lib)/Developer/Xcode/iOS DeviceSupport", category: .developer, owner: xcode,
                keepParent: true, exact: false),
            Def(path: "Projects/web-app/node_modules", category: .developer),
            Def(path: "Projects/api-server/node_modules", category: .developer),
            Def(path: "Projects/dashboard/node_modules", category: .developer),
            Def(path: ".npm/_cacache", category: .developer, keepParent: true, exact: false),
            Def(path: "\(lib)/Containers/com.docker.docker", category: .developer, tier: .review, mode: .none,
                owner: docker, note: "Reclaim space from Docker Desktop: Troubleshoot > Clean / Purge data."),
            Def(path: "\(lib)/Developer/CoreSimulator/Devices", category: .developer, tier: .review, mode: .simctl,
                exact: false, note: "Unavailable simulators", bytes: gb(3.2)),
            Def(path: ".Trash", category: .trash, tier: .review, keepParent: true),
        ]
    }

    static func cleanupSet(tree: StorageTree, now: Int64) -> (CleanupSet, inUse: Set<Int32>) {
        let home = MockStorageState.home
        var items: [CleanupItem] = []
        var inUse: Set<Int32> = []
        for def in defs() {
            let path = "\(home)/\(def.path)"
            let isNodeless = def.bytes != nil
            let node = isNodeless ? nil : tree.lookup(path: path)
            // Inside a dir the scan could not list (no Full Disk Access): the classifier never sees it.
            if !isNodeless, node == nil { continue }
            let id = Int32(items.count + 1)
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let alloc = def.bytes ?? node.flatMap { tree.size($0) } ?? 0
            let groups = linkGroups(under: node, tree: tree)
            let privateBytes: UInt64? = {
                guard def.exact, let node else { return nil }
                let credited = groups.filter { tree.isAncestor(node, of: tree.linkGroups[Int($0)].occurrences[0].node) }
                return alloc - UInt64(credited.count) * linkBytes
            }()
            items.append(CleanupItem(
                id: id, nodeID: node, path: path, name: isNodeless ? "Unavailable Simulators" : name,
                category: def.category, tier: def.tier, mode: def.mode,
                identity: node.map {
                    FileIdentity(dev: dev, ino: tree.fileID[Int($0)], isDirectory: tree.flags[Int($0)].contains(.directory))
                },
                allocBytes: alloc, privateBytesExcludingLinks: privateBytes, linkGroupIndices: groups,
                sizeProvenance: def.exact ? .exact : .estimate,
                lastUsed: node.map { Date(timeIntervalSince1970: TimeInterval(tree.subtreeMaxMtime[Int($0)])) },
                owner: def.owner, runningApp: def.running, keepParent: def.keepParent, ignored: def.ignored,
                note: def.note))
            if def.inUse { inUse.insert(id) }
        }
        let trashBytes = tree.lookup(path: "\(home)/.Trash").flatMap { tree.size($0) }
        let set = CleanupSet(treeVersion: tree.version, items: items, ownershipResolved: true,
                             privateSizesFinal: true, trashBytes: trashBytes)
        return (set, inUse)
    }

    private static func linkGroups(under node: StorageNodeID?, tree: StorageTree) -> [Int32] {
        guard let node else { return [] }
        return tree.linkGroups.indices.filter { g in
            tree.linkGroups[g].occurrences.contains { $0.node == node || tree.isAncestor(node, of: $0.node) }
        }.map { Int32($0) }
    }
}
