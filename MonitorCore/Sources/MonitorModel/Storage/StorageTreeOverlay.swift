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

/// Changes after cleaning or undo, applied over an immutable tree (no rebuild). Size changes are propagated to all
/// ancestors when written, so `size` is O(1) apart from the removed-ancestor check.
public struct StorageTreeOverlay: Sendable, Codable, Equatable {
    public private(set) var treeVersion: UInt64
    public private(set) var version: UInt64 = 0
    /// Node and its whole subtree are gone.
    public private(set) var removed: Set<StorageNodeID> = []
    /// Signed change per node: keep-parent partial removals, removed descendants, restores.
    public private(set) var sizeDelta: [StorageNodeID: Int64] = [:]
    public private(set) var restored: [RestoredEntry] = []

    public init(treeVersion: UInt64) {
        self.treeVersion = treeVersion
    }

    /// The same changes bound to `tree`, which must hold the same scan (a cache reload of the tree this overlay was
    /// recorded on: node ids are identical, only the process-local version differs).
    public func rebased(onto tree: StorageTree) -> StorageTreeOverlay {
        var copy = self
        copy.treeVersion = tree.version
        return copy
    }

    public var isEmpty: Bool { removed.isEmpty && sizeDelta.isEmpty && restored.isEmpty }

    /// Removes `node` and its subtree; its ancestors shrink by its current size. No-op if already removed.
    public mutating func remove(_ node: StorageNodeID, in tree: StorageTree) {
        guard !isRemoved(node, in: tree) else { return }
        let bytes = size(node, in: tree) ?? 0
        removed.insert(node)
        propagate(-Int64(clamping: bytes), fromParentOf: node, in: tree)
        version += 1
    }

    /// Keep-parent partial removal: `node` stays, it and its ancestors shrink by `bytes` (at most its size).
    public mutating func shrink(_ node: StorageNodeID, by bytes: UInt64, in tree: StorageTree) {
        guard !isRemoved(node, in: tree), let current = size(node, in: tree) else { return }
        let delta = -Int64(clamping: min(bytes, current))
        guard delta != 0 else { return }
        sizeDelta[node, default: 0] += delta
        propagate(delta, fromParentOf: node, in: tree)
        version += 1
    }

    /// Undo of a trashed item. Back under its original name and parent → the removed node returns with its size;
    /// otherwise (renamed "(restored)", or no node) the entry is added under `entry.parent` and its ancestors grow.
    public mutating func restore(_ entry: RestoredEntry, originalNode: StorageNodeID?, in tree: StorageTree) {
        if let node = originalNode, removed.contains(node), tree.parent[Int(node)] == entry.parent,
           tree.nameBytes(node).elementsEqual(entry.name.utf8) {
            removed.remove(node)
            if !isRemoved(node, in: tree) {
                propagate(Int64(clamping: size(node, in: tree) ?? 0), fromParentOf: node, in: tree)
            }
        } else {
            restored.append(entry)
            let delta = Int64(clamping: entry.bytes)
            sizeDelta[entry.parent, default: 0] += delta
            propagate(delta, fromParentOf: entry.parent, in: tree)
        }
        version += 1
    }

    /// Current size: tree size plus changes, floored at 0. nil if removed or restricted.
    public func size(_ node: StorageNodeID, in tree: StorageTree) -> UInt64? {
        guard !isRemoved(node, in: tree), let base = tree.size(node) else { return nil }
        let value = Int64(clamping: base) + (sizeDelta[node] ?? 0)
        return value > 0 ? UInt64(value) : 0
    }

    /// True if the node or any ancestor was removed.
    public func isRemoved(_ node: StorageNodeID, in tree: StorageTree) -> Bool {
        guard !removed.isEmpty else { return false }
        var n = node
        while true {
            if removed.contains(n) { return true }
            if n == 0 { return false }
            n = tree.parent[Int(n)]
        }
    }

    public func restoredEntries(under parent: StorageNodeID) -> [RestoredEntry] {
        restored.filter { $0.parent == parent }
    }

    private mutating func propagate(_ delta: Int64, fromParentOf node: StorageNodeID, in tree: StorageTree) {
        guard delta != 0, node != 0 else { return }
        var n = tree.parent[Int(node)]
        while true {
            sizeDelta[n, default: 0] += delta
            if n == 0 { return }
            n = tree.parent[Int(n)]
        }
    }
}
