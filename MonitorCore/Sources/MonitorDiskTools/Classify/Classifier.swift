import Foundation
import MonitorModel

/// Result of `Classifier.classify`: leftovers whose owner is not in the installed-app set are held back until
/// `resolve(_:found:)` has asked the platform where those bundle IDs live (spec §6.2 last step).
public struct ClassifyResult: Sendable {
    /// `ownershipResolved == false`; pending leftovers are not in `items`.
    public var set: CleanupSet
    /// Normalized IDs the engine must look up with `StoragePlatform.appPaths`.
    public var unresolvedBundleIDs: Set<String>
    let drafts: [Classifier.Draft]
}

/// Pure classification of a finished `StorageTree` into a `CleanupSet` (spec §6). No filesystem writes: platform
/// facts (git, toolchain, iCloud) arrive through injected seams.
public struct Classifier: Sendable {
    let home: String
    let dataDirectories: [String]
    let git: any GitTracking
    let devTools: any DevToolProbe
    let isUbiquitous: @Sendable (String) -> Bool

    /// `dataDirectories`: our own stores and staging dirs, never offered (together with `dev.telltale*` /
    /// `dev.warden*` names found anywhere in the tree).
    public init(home: String, dataDirectories: [String], git: any GitTracking, devTools: any DevToolProbe,
                isUbiquitous: @escaping @Sendable (String) -> Bool) {
        self.home = home
        self.dataDirectories = dataDirectories
        self.git = git
        self.devTools = devTools
        self.isUbiquitous = isUbiquitous
    }

    public func classify(tree: StorageTree, installed: InstalledAppSet, lastUsed: [String: Date],
                         options: ClassifyOptions) -> ClassifyResult {
        let drafts = ClassifyRun(classifier: self, tree: tree, installed: installed, lastUsed: lastUsed,
                                 options: options).drafts()
        let pending = drafts.filter { $0.pendingBundleID != nil }
        let set = CleanupSet(
            treeVersion: tree.version, items: Self.items(drafts.filter { $0.pendingBundleID == nil }),
            ownershipResolved: false, privateSizesFinal: false, trashBytes: ClassifyRun.trashBytes(tree, home: home))
        return ClassifyResult(set: set, unresolvedBundleIDs: Set(pending.compactMap(\.pendingBundleID)),
                              drafts: drafts)
    }

    /// `found[id]` non-empty means the platform knows an app for that ID: its data is not a leftover.
    public func resolve(_ result: ClassifyResult, found: [String: [String]]) -> CleanupSet {
        let kept = result.drafts.filter { draft in
            guard let id = draft.pendingBundleID else { return true }
            return found[id]?.isEmpty ?? true
        }
        var set = result.set
        set.items = Self.items(kept)
        set.ownershipResolved = true
        return set
    }

    // MARK: - Items

    struct Draft: Sendable {
        var node: StorageNodeID?
        var identity: FileIdentity?
        var path: String
        var name: String
        var category: CleanupCategory
        var tier: SafetyTier
        var mode: DeleteMode
        var allocBytes: UInt64
        var lastUsed: Date?
        var owner: OwnerApp?
        var keepParent: Bool
        var note: String?
        var ignored: Bool
        var linkGroupIndices: [Int32] = []
        /// Leftover whose owner is not installed as far as the set knows.
        var pendingBundleID: String?
    }

    /// Ids run 0… in (category, path) order so a re-run over the same tree is byte-identical.
    static func items(_ drafts: [Draft]) -> [CleanupItem] {
        let order = Dictionary(uniqueKeysWithValues: CleanupCategory.allCases.enumerated().map { ($1, $0) })
        let sorted = drafts.sorted { a, b in
            if a.category != b.category { return order[a.category, default: 0] < order[b.category, default: 0] }
            return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
        }
        return sorted.enumerated().map { index, d in
            CleanupItem(
                id: Int32(index), nodeID: d.node, path: d.path, name: d.name, category: d.category, tier: d.tier,
                mode: d.mode, identity: d.identity, allocBytes: d.allocBytes, linkGroupIndices: d.linkGroupIndices,
                sizeProvenance: .estimate, lastUsed: d.lastUsed, owner: d.owner, runningApp: false,
                keepParent: d.keepParent, ignored: d.ignored, note: d.note)
        }
    }
}

/// One classification pass: candidate generation per category, own-data exclusion, nested de-dupe.
struct ClassifyRun {
    let classifier: Classifier
    let tree: StorageTree
    let installed: InstalledAppSet
    let lastUsed: [String: Date]
    let options: ClassifyOptions

    private struct Candidate {
        var draft: Classifier.Draft
        /// Same-node ties: lower wins (Trash, Developer, User Caches, Leftovers, Large & Old).
        var rank: Int
    }

    static func trashBytes(_ tree: StorageTree, home: String) -> UInt64? {
        tree.lookup(path: home + "/.Trash").flatMap { tree.size($0) }
    }

    func drafts() -> [Classifier.Draft] {
        guard let homeNode = tree.lookup(path: classifier.home) else { return [] }
        let blocked = ownDataBlocked()
        let eligible = visibleTerritory(homeNode: homeNode)

        let userCaches = userCacheCandidates(blocked: blocked)
        let shadowed = Set(userCaches.compactMap(\.draft.node))
        let candidates = trashCandidates(blocked: blocked)
            + developerCandidates(homeNode: homeNode, eligible: eligible, blocked: blocked)
            + userCaches
            + leftoverCandidates(blocked: blocked, shadowedByUserCache: shadowed)
            + largeOldCandidates(homeNode: homeNode, eligible: eligible, blocked: blocked)

        // Largest matching subtree wins: ids grow with depth, so walking by node id sees outer dirs first, and an
        // inner candidate is dropped. One node matching several categories goes to the highest priority (`rank`).
        // Rows without a node or that are info-only (`.none`) never delete anything and skip the nesting check.
        var accepted: [Classifier.Draft] = []
        var taken = NestingIndex(tree: tree)
        for c in candidates.sorted(by: Self.byNode) {
            if let node = c.draft.node, c.draft.mode != .none, !taken.add(node) { continue }
            accepted.append(c.draft)
        }

        attachLinkGroups(&accepted)
        for i in accepted.indices { accepted[i].ignored = options.ignoredPaths.contains(accepted[i].path) }
        return accepted
    }

    private static func byNode(_ a: Candidate, _ b: Candidate) -> Bool {
        let na = a.draft.node ?? -1, nb = b.draft.node ?? -1
        return na != nb ? na < nb : a.rank < b.rank
    }

    // MARK: Tree helpers

    private func isHidden(_ node: Int) -> Bool {
        tree.flags[node].contains(.hidden) || tree.nameBytes(Int32(node)).first == UInt8(ascii: ".")
    }

    private func children(_ node: StorageNodeID) -> Range<Int> {
        let start = Int(tree.firstChild[Int(node)])
        return start ..< start + Int(tree.childCount[Int(node)])
    }

    private func child(_ node: StorageNodeID, _ name: String) -> StorageNodeID? {
        children(node).first { tree.nameBytes(Int32($0)).elementsEqual(name.utf8) }.map { Int32($0) }
    }

    /// Node at a home-relative path.
    private func node(_ relative: String) -> StorageNodeID? {
        var current = tree.lookup(path: classifier.home)
        for component in relative.split(separator: "/") {
            guard let c = current else { return nil }
            current = child(c, String(component))
        }
        return current
    }

    private func draft(_ node: StorageNodeID, category: CleanupCategory, tier: SafetyTier, mode: DeleteMode,
                       keepParent: Bool = false, owner: OwnerApp? = nil, note: String? = nil,
                       lastUsed: Date? = nil, pendingBundleID: String? = nil) -> Classifier.Draft {
        Classifier.Draft(
            node: node, identity: tree.identity(node), path: tree.path(node), name: tree.name(node),
            category: category, tier: tier, mode: mode, allocBytes: tree.size(node) ?? 0, lastUsed: lastUsed,
            owner: owner, keepParent: keepParent, note: note, ignored: false, pendingBundleID: pendingBundleID)
    }

    /// Usable as an item: known size, not empty.
    private func usable(_ node: StorageNodeID, blocked: [Bool]) -> Bool {
        !blocked[Int(node)] && !tree.flags[Int(node)].contains(.restricted) && tree.allocBytes[Int(node)] > 0
    }

    /// Nodes that are, contain or sit inside our own data (`dev.telltale*`, `dev.warden*`, injected dirs).
    private func ownDataBlocked() -> [Bool] {
        let count = tree.nodeCount
        var own = [Bool](repeating: false, count: count)
        for i in 1 ..< count where tree.nameLength[i] >= 10 && CategoryRules.isOwnDataName(tree.nameBytes(Int32(i))) {
            own[i] = true
        }
        for dir in classifier.dataDirectories {
            if let node = tree.lookup(path: dir) { own[Int(node)] = true }
        }
        // Inside: parent < child, so one forward pass.
        var blocked = own
        for i in 1 ..< count where blocked[Int(tree.parent[i])] { blocked[i] = true }
        // Contains: climb from every own node, stopping at an already marked ancestor.
        var contains = [Bool](repeating: false, count: count)
        for i in 0 ..< count where own[i] {
            var a = Int(tree.parent[i])
            while !contains[a] {
                contains[a] = true
                if a == 0 { break }
                a = Int(tree.parent[a])
            }
        }
        for i in 0 ..< count where contains[i] { blocked[i] = true }
        return blocked
    }

    /// `eligible[d]`: files and dirs inside `d` are in the visible part of `~` (no hidden dir, no `~/Library`, no
    /// package between `~` and `d`).
    private func visibleTerritory(homeNode: StorageNodeID) -> [Bool] {
        var eligible = [Bool](repeating: false, count: tree.nodeCount)
        eligible[Int(homeNode)] = true
        for i in Int(homeNode) + 1 ..< tree.nodeCount {
            let p = tree.parent[i]
            guard eligible[Int(p)], tree.flags[i].contains(.directory), !tree.flags[i].contains(.package),
                  !isHidden(i), !(p == homeNode && tree.name(Int32(i)) == "Library") else { continue }
            eligible[i] = true
        }
        return eligible
    }

    // MARK: Trash

    private func trashCandidates(blocked: [Bool]) -> [Candidate] {
        guard let trash = node(".Trash"), usable(trash, blocked: blocked) else { return [] }
        return [Candidate(draft: draft(trash, category: .trash, tier: .review, mode: .remove, keepParent: true),
                          rank: 0)]
    }

    // MARK: User Caches

    private func userCacheCandidates(blocked: [Bool]) -> [Candidate] {
        var out: [Candidate] = []
        func add(_ parent: StorageNodeID, owner containerID: String?) {
            for c in children(parent) {
                let node = Int32(c)
                let name = tree.name(node)
                guard usable(node, blocked: blocked), !CategoryRules.isSystemCacheName(name) else { continue }
                let id = BundleID.normalize(name)
                if let id, Self.isOffLimitsApple(id) { continue }
                let owner = (containerID ?? id).flatMap { installed.app(for: $0) }
                out.append(Candidate(
                    draft: draft(node, category: .userCaches, tier: .safe, mode: .remove,
                                 keepParent: tree.flags[c].contains(.directory), owner: owner),
                    rank: 2))
            }
        }
        for rel in CategoryRules.cacheParents {
            if let parent = node(rel) { add(parent, owner: nil) }
        }
        if let containers = node(CategoryRules.containersDir) {
            for c in children(containers) {
                let name = tree.name(Int32(c))
                let id = BundleID.normalize(name)
                if let id, Self.isOffLimitsApple(id) { continue }
                var caches: StorageNodeID? = Int32(c)
                for component in CategoryRules.containerCachesSubpath {
                    caches = caches.flatMap { child($0, component) }
                }
                if let caches { add(caches, owner: id) }
            }
        }
        return out
    }

    private static func isOffLimitsApple(_ id: String) -> Bool {
        BundleID.isAppleOwned(id) && !CategoryRules.appleAllowlist.contains(id)
    }

    // MARK: Leftovers

    private func leftoverCandidates(blocked: [Bool], shadowedByUserCache: Set<StorageNodeID>) -> [Candidate] {
        var out: [Candidate] = []
        for rel in CategoryRules.leftoverParents {
            guard let parent = node(rel) else { continue }
            for c in children(parent) {
                let node = Int32(c)
                guard usable(node, blocked: blocked), !shadowedByUserCache.contains(node) else { continue }
                let name = tree.name(node)
                guard !CategoryRules.isSystemCacheName(name), let id = BundleID.normalize(name),
                      !BundleID.isAppleOwned(id), !installed.owns(id) else { continue }
                let touched = Double(tree.subtreeMaxMtime[c])
                guard options.now.timeIntervalSince1970 - touched >= CategoryRules.leftoverAge else { continue }
                out.append(Candidate(
                    draft: draft(node, category: .leftovers, tier: .review, mode: .trash,
                                 lastUsed: Date(timeIntervalSince1970: touched), pendingBundleID: id),
                    rank: 3))
            }
        }
        return out
    }

    // MARK: Large & Old

    private func largeOldCandidates(homeNode: StorageNodeID, eligible: [Bool], blocked: [Bool]) -> [Candidate] {
        var out: [Candidate] = []
        let minBytes = min(options.largeBytes, options.oldBytes)
        for i in Int(homeNode) + 1 ..< tree.nodeCount {
            let flags = tree.flags[i]
            guard tree.allocBytes[i] >= minBytes, eligible[Int(tree.parent[i])],
                  flags.isDisjoint(with: [.directory, .package, .symlink, .restricted, .dataless]),
                  !isHidden(i), !blocked[i] else { continue }
            let node = Int32(i)
            let path = tree.path(node)
            var used = max(tree.mtime[i], tree.addedTime[i])
            if let spotlight = lastUsed[path] { used = max(used, Int64(spotlight.timeIntervalSince1970)) }
            let usedDate = Date(timeIntervalSince1970: Double(used))
            let bytes = tree.allocBytes[i]
            let isOld = bytes >= options.oldBytes && options.now.timeIntervalSince(usedDate) >= options.oldAge
            guard bytes >= options.largeBytes || isOld else { continue }
            out.append(Candidate(
                draft: draft(node, category: .largeOld, tier: .review,
                             mode: classifier.isUbiquitous(path) ? .evict : .trash, lastUsed: usedDate),
                rank: 4))
        }
        return out
    }

    // MARK: Developer

    private func developerCandidates(homeNode: StorageNodeID, eligible: [Bool], blocked: [Bool]) -> [Candidate] {
        var out: [Candidate] = []
        func add(_ d: Classifier.Draft) { out.append(Candidate(draft: d, rank: 1)) }

        for (rel, label) in CategoryRules.developerSafePaths {
            if let node = node(rel), usable(node, blocked: blocked) {
                add(draft(node, category: .developer, tier: .safe, mode: .remove, note: label))
            }
        }
        for rel in CategoryRules.deviceSupportDirs {
            guard let dir = node(rel) else { continue }
            let versions = children(dir).filter { tree.flags[$0].contains(.directory) }
            // Newest by mtime stays (ties: later name), the only copy a connected device may still need.
            let newest = versions.max { a, b in
                tree.mtime[a] != tree.mtime[b] ? tree.mtime[a] < tree.mtime[b] : tree.name(Int32(a)) < tree.name(Int32(b))
            }
            for v in versions where v != newest && usable(Int32(v), blocked: blocked) {
                add(draft(Int32(v), category: .developer, tier: .review, mode: .remove,
                          note: (rel as NSString).lastPathComponent))
            }
        }
        for d in archiveDrafts(blocked: blocked) { add(d) }
        for rel in CategoryRules.dockerImages {
            if let node = node(rel), usable(node, blocked: blocked) {
                add(draft(node, category: .developer, tier: .review, mode: .none, note: CategoryRules.dockerNote))
            }
        }
        let toolchain = Toolchain(devTools: classifier.devTools)
        if let sims = simulatorDraft(toolchain: toolchain) { add(sims) }
        for d in buildDirDrafts(homeNode: homeNode, eligible: eligible, blocked: blocked, toolchain: toolchain) {
            add(d)
        }
        return out
    }

    /// `xcode-select -p` is probed at most once per pass and only if a rule needs the toolchain.
    private final class Toolchain {
        private let devTools: any DevToolProbe
        private var cached: Bool?
        init(devTools: any DevToolProbe) { self.devTools = devTools }
        var ok: Bool {
            if let cached { return cached }
            let value = devTools.xcodeSelectOK
            cached = value
            return value
        }
        var simulatorUDIDs: [String] { devTools.unavailableSimulatorUDIDs() }
    }

    private func archiveDrafts(blocked: [Bool]) -> [Classifier.Draft] {
        guard let archives = node(CategoryRules.archivesDir) else { return [] }
        var found: [StorageNodeID] = []
        for c in children(archives) {
            if tree.name(Int32(c)).hasSuffix(".xcarchive") {
                found.append(Int32(c))
            } else if tree.flags[c].contains(.directory) {
                // Organizer groups archives in `YYYY-MM-DD` dirs.
                found.append(contentsOf: children(Int32(c)).filter { tree.name(Int32($0)).hasSuffix(".xcarchive") }
                    .map { Int32($0) })
            }
        }
        return found.filter {
            usable($0, blocked: blocked)
                && options.now.timeIntervalSince1970 - Double(tree.subtreeMaxMtime[Int($0)]) >= CategoryRules.archivesAge
        }.map {
            draft($0, category: .developer, tier: .review, mode: .trash,
                  lastUsed: Date(timeIntervalSince1970: Double(tree.subtreeMaxMtime[Int($0)])))
        }
    }

    /// One row for `xcrun simctl delete unavailable`: no single node, so size is the sum of the matching device dirs.
    private func simulatorDraft(toolchain: Toolchain) -> Classifier.Draft? {
        guard let devices = node(CategoryRules.simulatorDevicesDir), toolchain.ok else { return nil }
        let udids = Set(toolchain.simulatorUDIDs)
        let matching = children(devices).filter { udids.contains(tree.name(Int32($0))) }
        let bytes = matching.reduce(into: UInt64(0)) { $0 += tree.size(Int32($1)) ?? 0 }
        guard bytes > 0 else { return nil }
        return Classifier.Draft(
            node: nil, identity: nil, path: tree.path(devices), name: "Unavailable simulators",
            category: .developer, tier: .review, mode: .simctl, allocBytes: bytes, lastUsed: nil, owner: nil,
            keepParent: false, note: "\(matching.count) unavailable simulators", ignored: false)
    }

    // MARK: Build dirs

    private func buildDirDrafts(homeNode: StorageNodeID, eligible: [Bool], blocked: [Bool],
                                toolchain: Toolchain) -> [Classifier.Draft] {
        var cheap: [(node: StorageNodeID, project: StorageNodeID)] = []
        for i in Int(homeNode) + 1 ..< tree.nodeCount where tree.flags[i].contains(.buildDir) {
            let node = Int32(i)
            guard eligible[Int(tree.parent[i])], usable(node, blocked: blocked),
                  let required = BuildDirRules.requiredMarkers(forName: tree.name(node)),
                  !tree.markerMask[i].isDisjoint(with: required),
                  let project = BuildDirRules.project(of: node, in: tree, limit: homeNode),
                  options.now.timeIntervalSince1970 - Double(tree.subtreeMaxMtime[Int(project)])
                  >= BuildDirRules.projectAge else { continue }
            cheap.append((node, project))
        }
        // Outermost first, so git is asked about `node_modules` and not about nested copies.
        var outer = NestingIndex(tree: tree)
        cheap = cheap.filter { outer.add($0.node) }
        guard !cheap.isEmpty, toolchain.ok else { return [] }
        return cheap.compactMap { entry in
            let dir = tree.path(entry.node)
            guard !classifier.git.hasTrackedFiles(project: tree.path(entry.project), dir: dir) else { return nil }
            return draft(entry.node, category: .developer, tier: .review, mode: .remove,
                         note: "Build output of \(tree.name(entry.project))")
        }
    }

    // MARK: Hard links

    /// Groups with a link inside each item: feeds `ReclaimAccumulator`'s union-aware byte count.
    private func attachLinkGroups(_ drafts: inout [Classifier.Draft]) {
        var byNode: [StorageNodeID: Int] = [:]
        for (i, d) in drafts.enumerated() { if let node = d.node { byNode[node] = i } }
        guard let lowest = byNode.keys.min() else { return }
        for (g, group) in tree.linkGroups.enumerated() {
            for occurrence in group.occurrences {
                var n = occurrence.node
                while n >= lowest {
                    if let i = byNode[n] {
                        if drafts[i].linkGroupIndices.last != Int32(g) { drafts[i].linkGroupIndices.append(Int32(g)) }
                        break
                    }
                    if n == 0 { break }
                    n = tree.parent[Int(n)]
                }
            }
        }
    }
}

/// Set of nodes where none is inside another: `add` refuses a node that is, contains or sits inside a member.
private struct NestingIndex {
    let tree: StorageTree
    private var members: Set<StorageNodeID> = []
    private var ancestors: Set<StorageNodeID> = []

    init(tree: StorageTree) { self.tree = tree }

    mutating func add(_ node: StorageNodeID) -> Bool {
        if members.contains(node) || ancestors.contains(node) { return false }
        var n = node
        while n != 0 {
            n = tree.parent[Int(n)]
            if members.contains(n) { return false }
        }
        members.insert(node)
        n = node
        while n != 0 {
            n = tree.parent[Int(n)]
            if !ancestors.insert(n).inserted { break }
        }
        return true
    }
}
