import Foundation

/// An item put back from the Trash under a node of the tree (the tree itself never changes).
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
    /// The overlay was recorded on another tree (a different version, or a different scan for `rebased(onto:)`).
    case treeMismatch
}

/// Changes after cleaning or undo, applied over an immutable tree (no rebuild). Size changes are propagated to the
/// ancestors when written, so `size` costs one walk to the root.
///
/// Visibility: a removed node hides its subtree. Undo into a removed directory "recreates" the missing ancestors:
/// a recreated node is visible but holds only what was restored into it; its original children stay hidden.
/// Hard links: each group's Space Map bytes sit at its first surviving occurrence (the tree credits the first one);
/// when that occurrence goes, the bytes move to the next survivor.
public struct StorageTreeOverlay: Sendable, Codable, Equatable {
    /// How an item left the tree: a deleted link no longer exists, a trashed one still pins the file's blocks.
    public enum RemovalKind: String, Sendable, Codable {
        case deleted, trashed
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
    /// Nodes removed explicitly (a node stays here while recreated).
    public private(set) var removed: Set<StorageNodeID> = []
    /// Revived without their original contents (missing parents of an undo).
    public private(set) var recreated: Set<StorageNodeID> = []
    /// Removed nodes put back with their contents by undo.
    public private(set) var revived: Set<StorageNodeID> = []
    /// Signed change per node; for a recreated node, its whole size.
    public private(set) var sizeDelta: [StorageNodeID: Int128] = [:]
    public private(set) var restored: [RestoredEntry] = []
    /// Group index → occurrence index that holds the group's map bytes (absent = 0, the tree's credit).
    public private(set) var linkHolder: [Int32: Int32] = [:]
    /// Group index → occurrence index → how that link left.
    public private(set) var goneLinks: [Int32: [Int32: RemovalKind]] = [:]

    public init(tree: StorageTree) {
        treeVersion = tree.version
        scan = ScanIdentity(tree)
    }

    /// The same changes bound to `tree`, which must hold the same scan (a cache reload: same root, volume, scan date
    /// and node count; only the process-local version differs).
    public func rebased(onto tree: StorageTree) throws(StorageOverlayError) -> StorageTreeOverlay {
        guard ScanIdentity(tree) == scan else { throw .treeMismatch }
        var copy = self
        copy.treeVersion = tree.version
        return copy
    }

    public var isEmpty: Bool { removed.isEmpty && sizeDelta.isEmpty && restored.isEmpty }

    // MARK: - Mutations

    /// Removes `node` and its subtree; its ancestors shrink by its current size. No-op if already hidden.
    public mutating func remove(_ node: StorageNodeID, kind: RemovalKind,
                                in tree: StorageTree) throws(StorageOverlayError) {
        try check(tree)
        guard !hidden(node, tree) else { return }
        if node != 0 {
            propagate(-Int128(size(visible: node, tree)), from: tree.parent[Int(node)], tree)
        }
        removed.insert(node)
        recreated.remove(node)
        revived.remove(node)
        settleLinks(under: node, .removed(kind), tree)
        version += 1
    }

    /// Keep-parent partial removal: `node` stays, it and its ancestors shrink by `bytes` (at most its size).
    /// Folded hard links inside it are not marked gone (unknown which small files went), so they never become
    /// reclaimable through it.
    public mutating func shrink(_ node: StorageNodeID, by bytes: UInt64,
                                in tree: StorageTree) throws(StorageOverlayError) {
        try check(tree)
        guard !hidden(node, tree), tree.size(node) != nil || recreated.contains(node) else { return }
        let delta = -Int128(min(bytes, size(visible: node, tree)))
        guard delta != 0 else { return }
        propagate(delta, from: node, tree)
        version += 1
    }

    /// Undo of a trashed item. Back under its original name and parent → the removed node returns with its
    /// contents; otherwise (renamed "(restored)", or no node) the entry is added under `entry.parent`. Hidden
    /// ancestors of the destination are recreated first (visible, holding only restored items).
    public mutating func restore(_ entry: RestoredEntry, originalNode: StorageNodeID?,
                                 in tree: StorageTree) throws(StorageOverlayError) {
        try check(tree)
        recreateHiddenAncestors(from: entry.parent, tree)
        if let node = originalNode, removed.contains(node), !recreated.contains(node),
           tree.parent[Int(node)] == entry.parent, tree.nameBytes(node).elementsEqual(entry.name.utf8) {
            removed.remove(node)
            revived.insert(node)
            propagate(Int128(size(visible: node, tree)), from: entry.parent, tree)
            settleLinks(under: node, .revived, tree)
        } else {
            restored.append(entry)
            propagate(Int128(entry.bytes), from: entry.parent, tree)
        }
        version += 1
    }

    // MARK: - Reads

    /// Current size: tree size plus changes, clamped to 0…UInt64.max. nil if hidden or restricted.
    public func size(_ node: StorageNodeID, in tree: StorageTree) throws(StorageOverlayError) -> UInt64? {
        try check(tree)
        guard !hidden(node, tree) else { return nil }
        if !recreated.contains(node), tree.size(node) == nil { return nil }
        return size(visible: node, tree)
    }

    /// True if the node is hidden: removed, inside a removed subtree, or original content of a recreated dir.
    public func isRemoved(_ node: StorageNodeID, in tree: StorageTree) throws(StorageOverlayError) -> Bool {
        try check(tree)
        return hidden(node, tree)
    }

    public func restoredEntries(under parent: StorageNodeID) -> [RestoredEntry] {
        restored.filter { $0.parent == parent }
    }

    /// Links of group `g` that no longer exist anywhere (permanently deleted); trashed links still count.
    public func deletedLinkCount(group g: Int32) -> Int {
        goneLinks[g]?.values.filter { $0 == .deleted }.count ?? 0
    }

    /// Whether occurrence `k` of group `g` is still in the visible tree.
    public func linkSurvives(group g: Int32, occurrence k: Int32) -> Bool {
        goneLinks[g]?[k] == nil
    }

    // MARK: - Private

    private func check(_ tree: StorageTree) throws(StorageOverlayError) {
        guard tree.version == treeVersion else { throw .treeMismatch }
    }

    private func size(visible node: StorageNodeID, _ tree: StorageTree) -> UInt64 {
        let delta = sizeDelta[node] ?? 0
        let value = recreated.contains(node) ? delta : Int128(tree.size(node) ?? 0) + delta
        return value <= 0 ? 0 : UInt64(clamping: value)
    }

    /// A node whose contents don't reach its parent: explicitly removed (and not recreated), or an original child of
    /// a recreated dir.
    private func isBoundary(_ m: StorageNodeID, _ tree: StorageTree) -> Bool {
        if recreated.contains(m) || revived.contains(m) { return false }
        if removed.contains(m) { return true }
        return m != 0 && recreated.contains(tree.parent[Int(m)])
    }

    private func hidden(_ node: StorageNodeID, _ tree: StorageTree) -> Bool {
        guard !removed.isEmpty else { return false }
        var m = node
        while true {
            if isBoundary(m, tree) { return true }
            if m == 0 { return false }
            m = tree.parent[Int(m)]
        }
    }

    /// Adds `delta` at `node` and its ancestors, stopping after the first boundary (whatever is above it already
    /// excludes that subtree).
    private mutating func propagate(_ delta: Int128, from node: StorageNodeID, _ tree: StorageTree) {
        guard delta != 0 else { return }
        var m = node
        while true {
            sizeDelta[m, default: 0] += delta
            if m == 0 || isBoundary(m, tree) { return }
            m = tree.parent[Int(m)]
        }
    }

    /// Makes every hidden node from `node` up to the first visible ancestor a recreated, empty dir.
    private mutating func recreateHiddenAncestors(from node: StorageNodeID, _ tree: StorageTree) {
        var chain: [StorageNodeID] = []
        var m = node
        while hidden(m, tree) {
            chain.append(m)
            if m == 0 { break }
            m = tree.parent[Int(m)]
        }
        for n in chain {
            recreated.insert(n)
            revived.remove(n)
            sizeDelta[n] = 0
        }
    }

    private enum LinkChange {
        /// Occurrences not yet gone leave with this kind.
        case removed(RemovalKind)
        /// Occurrences come back unless something else still hides them (a separately removed descendant).
        case revived
    }

    /// Updates `goneLinks` for occurrences inside `node`'s subtree, then moves each affected group's map bytes to its
    /// first surviving occurrence.
    private mutating func settleLinks(under node: StorageNodeID, _ change: LinkChange, _ tree: StorageTree) {
        for (gi, group) in tree.linkGroups.enumerated() {
            let g = Int32(gi)
            var touched = false
            for (ki, occ) in group.occurrences.enumerated()
            where occ.node == node || tree.isAncestor(node, of: occ.node) {
                let k = Int32(ki)
                switch change {
                case let .removed(kind):
                    if goneLinks[g]?[k] == nil { goneLinks[g, default: [:]][k] = kind }
                case .revived:
                    if !hidden(occ.node, tree) { goneLinks[g]?[k] = nil }
                }
                touched = true
            }
            guard touched else { continue }
            if goneLinks[g]?.isEmpty == true { goneLinks[g] = nil }
            let holder = linkHolder[g] ?? 0
            guard let first = group.occurrences.indices.first(where: { goneLinks[g]?[Int32($0)] == nil }),
                  Int32(first) != holder else { continue }
            let bytes = Int128(group.allocBytes)
            propagate(-bytes, from: group.occurrences[Int(holder)].node, tree)
            propagate(bytes, from: group.occurrences[first].node, tree)
            linkHolder[g] = first == 0 ? nil : Int32(first)
        }
    }
}
