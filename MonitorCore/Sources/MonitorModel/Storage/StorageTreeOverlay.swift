import Foundation

/// An item put back from the Trash that has no node in the tree; it shows under `parent` with `bytes`.
public struct RestoredEntry: Sendable, Codable, Equatable {
    public var parent: StorageNodeID
    /// Final name, e.g. "name (restored)" when the original name was taken.
    public var name: String
    public var bytes: UInt64
    public var itemID: Int32

    public init(parent: StorageNodeID, name: String, bytes: UInt64, itemID: Int32) {
        self.parent = parent
        self.name = name
        self.bytes = bytes
        self.itemID = itemID
    }
}

public enum StorageOverlayError: Error, Equatable, Sendable {
    /// The overlay was recorded on another tree (a different version, or a different scan for `rebased(onto:)`),
    /// or was decoded and not yet `rebased(onto:)` a tree.
    case treeMismatch
}

/// Changes after cleaning or undo over an immutable tree, kept as a declarative record of where each node's content
/// physically is; every size, visibility and hard-link credit is recomputed from that record in one O(nodes) pass
/// per change (no incremental bookkeeping).
///
/// Model: a node has its *original* instance (the scanned content: own files, folded small files, folded links) and
/// possibly a *recreated* instance (an empty dir made by undo when a restored item's parent was gone). Each instance is
/// live, in a Trash snapshot, or deleted. Removing a visible node moves everything live in its subtree (original and
/// recreated instances, restored entries) into one new snapshot (trash) or to deleted. Undo of a node moves its latest
/// snapshot's content back and recreates hidden ancestors. A node is visible iff one of its instances is live.
/// Hard links: a group's Space Map bytes sit at its first occurrence (tree order: depth, path) whose original
/// instance is live; occurrences whose content is deleted no longer exist (reclaim needs fewer links), trashed ones
/// still do.
public struct StorageTreeOverlay: Sendable, Codable, Equatable {
    /// How an item left the tree: a deleted link no longer exists, a trashed one still pins the file's blocks.
    public enum RemovalKind: String, Sendable, Codable {
        case deleted, trashed
    }

    public enum Location: Sendable, Codable, Equatable, Hashable {
        case live
        case trashed(snapshot: Int32)
        case deleted
    }

    /// What identifies a scan independently of the process-local `StorageTree.version`.
    public struct ScanIdentity: Sendable, Codable, Equatable {
        public var root: ScanRoot
        public var volumeUUID: UUID?
        public var scanDate: Date
        public var nodeCount: Int

        public init(_ tree: StorageTree) {
            root = tree.root
            volumeUUID = tree.volumeUUID
            scanDate = tree.scanDate
            nodeCount = tree.nodeCount
        }
    }

    public private(set) var treeVersion: UInt64
    public let scan: ScanIdentity
    public private(set) var version: UInt64 = 0
    /// Original instance per node; absent = live.
    public private(set) var original: [StorageNodeID: Location] = [:]
    /// Recreated (empty) instance per node; absent = none.
    /// Recreated (empty) instances per node: several can exist (one live, others in different Trash snapshots);
    /// deleted ones are dropped.
    public private(set) var recreated: [StorageNodeID: Set<Location>] = [:]
    /// Display name of an original / recreated instance restored under another name.
    public private(set) var renamed: [StorageNodeID: String] = [:]
    public private(set) var renamedRecreated: [StorageNodeID: String] = [:]
    /// Restored items without a tree node, with their location (parallel arrays).
    public private(set) var restored: [RestoredEntry] = []
    public private(set) var restoredLocations: [Location] = []
    /// Root node of each Trash snapshot still holding content.
    public private(set) var trashRoots: [Int32: StorageNodeID] = [:]
    /// Keep-parent partial removals, taken off the node's size (clamped at 0).
    public private(set) var shrunk: [StorageNodeID: UInt128] = [:]
    private var nextSnapshot: Int32 = 0
    private var derived: Derived?

    private enum CodingKeys: String, CodingKey {
        case treeVersion, scan, version, original, recreated, renamed, renamedRecreated, restored, restoredLocations, trashRoots, shrunk,
             nextSnapshot
    }

    public init(tree: StorageTree) {
        treeVersion = tree.version
        scan = ScanIdentity(tree)
        derived = Self.derive(tree: tree, from: self)
    }

    /// The same changes bound to `tree`, which must hold the same scan (a cache reload: same root, volume, scan date
    /// and node count; only the process-local version differs). Required after decoding.
    public func rebased(onto tree: StorageTree) throws(StorageOverlayError) -> StorageTreeOverlay {
        guard ScanIdentity(tree) == scan else { throw .treeMismatch }
        var copy = self
        copy.treeVersion = tree.version
        copy.derived = Self.derive(tree: tree, from: copy)
        return copy
    }

    public var isEmpty: Bool { original.isEmpty && recreated.isEmpty && restored.isEmpty && shrunk.isEmpty }

    // MARK: - Mutations

    /// Moves everything live in `node`'s subtree to a new Trash snapshot or to deleted. No-op if `node` is hidden.
    public mutating func remove(_ node: StorageNodeID, kind: RemovalKind,
                                in tree: StorageTree) throws(StorageOverlayError) {
        try check(tree)
        guard isVisible(node) else { return }
        let target: Location
        switch kind {
        case .deleted:
            target = .deleted
        case .trashed:
            target = .trashed(snapshot: nextSnapshot)
            trashRoots[nextSnapshot] = node
            nextSnapshot += 1
        }
        for d in Self.subtree(of: node, tree) {
            if (original[d] ?? .live) == .live { original[d] = target }
            if recreated[d]?.remove(.live) != nil, target != .deleted { recreated[d, default: []].insert(target) }
            if recreated[d]?.isEmpty == true { recreated[d] = nil }
        }
        for i in restored.indices where restoredLocations[i] == .live && Self.within(restored[i].parent, node, tree) {
            restoredLocations[i] = target
        }
        commit(tree)
    }

    /// Keep-parent partial removal: `node` stays, its size drops by `bytes` (floored at 0). Folded hard links inside
    /// it stay (unknown which small files went), so they never become reclaimable through it.
    public mutating func shrink(_ node: StorageNodeID, by bytes: UInt64,
                                in tree: StorageTree) throws(StorageOverlayError) {
        try check(tree)
        guard isVisible(node), bytes > 0 else { return }
        shrunk[node, default: 0] += UInt128(bytes)
        commit(tree)
    }

    /// Undo of a trashed item. With `originalNode` (hidden, child of `entry.parent`): its latest Trash snapshot comes
    /// back, shown as `entry.name` (a rename if it differs). Otherwise the entry is added under `entry.parent` with
    /// `entry.bytes`. Either way hidden ancestors of `entry.parent` are recreated as empty dirs.
    public mutating func restore(_ entry: RestoredEntry, originalNode: StorageNodeID?,
                                 in tree: StorageTree) throws(StorageOverlayError) {
        try check(tree)
        if let node = originalNode, node != 0, tree.parent[Int(node)] == entry.parent, !isVisible(node),
           let snapshot = trashRoots.filter({ $0.value == node }).keys.max() {
            let source = Location.trashed(snapshot: snapshot)
            // The snapshot holds either the node's original instance or its recreated one; the name goes with it.
            let newName = tree.nameBytes(node).elementsEqual(entry.name.utf8) ? nil : entry.name
            if original[node] == source { renamed[node] = newName } else { renamedRecreated[node] = newName }
            for d in Self.subtree(of: node, tree) {
                if original[d] == source { original[d] = nil }
                if recreated[d]?.remove(source) != nil { recreated[d, default: []].insert(.live) }
            }
            for i in restored.indices where restoredLocations[i] == source { restoredLocations[i] = .live }
            trashRoots[snapshot] = nil
        } else {
            restored.append(entry)
            restoredLocations.append(.live)
        }
        var m = entry.parent
        while !isVisible(m) {
            recreated[m, default: []].insert(.live)
            renamedRecreated[m] = nil
            if m == 0 { break }
            m = tree.parent[Int(m)]
        }
        commit(tree)
    }

    // MARK: - Reads

    /// Current size, clamped to 0…UInt64.max. nil if hidden, or restricted (unknown) in its scanned form.
    public func size(_ node: StorageNodeID, in tree: StorageTree) throws(StorageOverlayError) -> UInt64? {
        let d = try derivedState(tree)
        guard isVisible(node) else { return nil }
        if tree.flags[Int(node)].contains(.restricted), recreated[node]?.contains(.live) != true { return nil }
        return d.size[Int(node)]
    }

    /// True if no instance of the node is live (removed, inside a removed subtree, or original content of a
    /// recreated dir).
    public func isRemoved(_ node: StorageNodeID, in tree: StorageTree) throws(StorageOverlayError) -> Bool {
        _ = try derivedState(tree)
        return !isVisible(node)
    }

    /// Display name of the live instance (a restore may have renamed it).
    public func name(_ node: StorageNodeID, in tree: StorageTree) throws(StorageOverlayError) -> String {
        _ = try derivedState(tree)
        let name = (original[node] ?? .live) == .live ? renamed[node] : renamedRecreated[node]
        return name ?? tree.name(node)
    }

    /// Live restored entries without a node under `parent`.
    public func restoredEntries(under parent: StorageNodeID) -> [RestoredEntry] {
        restored.indices.filter { restored[$0].parent == parent && restoredLocations[$0] == .live }
            .map { restored[$0] }
    }

    /// Links of group `g` that no longer exist anywhere (deleted); trashed links still count.
    public func deletedLinkCount(group g: Int32) -> Int {
        derived?.deletedLinks[g] ?? 0
    }

    /// Whether occurrence `k` of group `g` is in the visible tree.
    public func linkSurvives(group g: Int32, occurrence k: Int32) -> Bool {
        !(derived?.hiddenLinks[g]?.contains(k) ?? false)
    }

    // MARK: - Derivation

    private struct Derived: Sendable, Equatable {
        var size: [UInt64]
        var deletedLinks: [Int32: Int]
        var hiddenLinks: [Int32: Set<Int32>]
    }

    private func check(_ tree: StorageTree) throws(StorageOverlayError) {
        guard tree.version == treeVersion, derived != nil else { throw .treeMismatch }
    }

    private func derivedState(_ tree: StorageTree) throws(StorageOverlayError) -> Derived {
        guard tree.version == treeVersion, let derived else { throw .treeMismatch }
        return derived
    }

    private func isVisible(_ node: StorageNodeID) -> Bool {
        (original[node] ?? .live) == .live || recreated[node]?.contains(.live) == true
    }

    private mutating func commit(_ tree: StorageTree) {
        derived = Self.derive(tree: tree, from: self)
        version += 1
    }

    private static func within(_ node: StorageNodeID, _ root: StorageNodeID, _ tree: StorageTree) -> Bool {
        node == root || tree.isAncestor(root, of: node)
    }

    private static func subtree(of node: StorageNodeID, _ tree: StorageTree) -> [StorageNodeID] {
        var out: [StorageNodeID] = []
        var stack = [node]
        while let n = stack.popLast() {
            out.append(n)
            let start = tree.firstChild[Int(n)]
            stack.append(contentsOf: start ..< start + tree.childCount[Int(n)])
        }
        return out
    }

    /// One pass over tree + record: own content of live original instances (tree size minus children minus the
    /// tree's link credit), live restored entries, each link group's bytes at its first live occurrence, then a
    /// reverse rollup over visible nodes in 128 bits.
    private static func derive(tree: StorageTree, from o: StorageTreeOverlay) -> Derived {
        let n = tree.nodeCount
        let originalLive: (Int) -> Bool = { (o.original[StorageNodeID($0)] ?? .live) == .live }
        var childSum = [UInt64](repeating: 0, count: n)
        for i in stride(from: 1, to: n, by: 1) { childSum[Int(tree.parent[i])] += tree.allocBytes[i] }
        var own = [UInt128](repeating: 0, count: n)
        for i in 0 ..< n where originalLive(i) && !tree.flags[i].contains(.restricted) {
            own[i] = UInt128(tree.allocBytes[i]) - UInt128(childSum[i])
        }
        for group in tree.linkGroups {
            guard let first = group.occurrences.first, !tree.flags[Int(first.node)].contains(.restricted),
                  originalLive(Int(first.node)) else { continue }
            own[Int(first.node)] -= UInt128(group.allocBytes)
        }
        for (i, entry) in o.restored.enumerated() where o.restoredLocations[i] == .live {
            own[Int(entry.parent)] += UInt128(entry.bytes)
        }
        var deletedLinks: [Int32: Int] = [:]
        var hiddenLinks: [Int32: Set<Int32>] = [:]
        for (gi, group) in tree.linkGroups.enumerated() {
            var credited = false
            for (k, occ) in group.occurrences.enumerated() {
                switch o.original[occ.node] ?? .live {
                case .live:
                    if !credited, !tree.flags[Int(occ.node)].contains(.restricted) {
                        own[Int(occ.node)] += UInt128(group.allocBytes)
                        credited = true
                    }
                case .deleted:
                    deletedLinks[Int32(gi), default: 0] += 1
                    hiddenLinks[Int32(gi), default: []].insert(Int32(k))
                case .trashed:
                    hiddenLinks[Int32(gi), default: []].insert(Int32(k))
                }
            }
        }
        var total = [UInt128](repeating: 0, count: n)
        var size = [UInt64](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var t = own[i] + total[i]
            if originalLive(i), let s = o.shrunk[StorageNodeID(i)] { t -= min(s, t) }
            size[i] = UInt64(clamping: t)
            let visible = originalLive(i) || o.recreated[StorageNodeID(i)]?.contains(.live) == true
            let unknown = tree.flags[i].contains(.restricted) && originalLive(i)
            if i > 0, visible, !unknown { total[Int(tree.parent[i])] += t }
        }
        return Derived(size: size, deletedLinks: deletedLinks, hiddenLinks: hiddenLinks)
    }
}
