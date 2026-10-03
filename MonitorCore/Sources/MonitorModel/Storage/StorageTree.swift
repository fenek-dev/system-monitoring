import Foundation
import Synchronization

/// Immutable struct-of-arrays snapshot of a scan. A swap is one reference assignment; views compare `version`.
///
/// Layout invariants: index = `StorageNodeID`, node 0 is the root, `parent[i] < i`, a node's children are the
/// contiguous range `firstChild[i] ..< firstChild[i] + childCount[i]` in allocation order. `childOrder` holds the same
/// ranges re-sorted by size (desc, ties by name), so ids stay stable when sizes are ordered.
public final class StorageTree: Sendable {
    public let version: UInt64
    public let root: ScanRoot
    public let volumeUUID: UUID?
    public let dev: Int32
    public let scanDate: Date
    /// FSEvents id at scan start, for a later "changed since scan" badge.
    public let lastEventId: UInt64

    public let parent: [Int32]
    public let firstChild: [Int32]
    public let childCount: [Int32]
    /// Rolled up (own + folded small files + descendants); restricted nodes hold and contribute 0.
    public let allocBytes: [UInt64]
    public let smallBytes: [UInt64]
    public let smallCount: [UInt32]
    public let fileID: [UInt64]
    public let mtime: [Int64]
    /// Max mtime over the subtree incl. folded small files, excluding `.buildDir` children.
    public let subtreeMaxMtime: [Int64]
    public let addedTime: [Int64]
    public let flags: [StorageNodeFlags]
    public let markerMask: [StorageMarker]
    public let nameOffset: [UInt32]
    public let nameLength: [UInt16]
    public let names: [UInt8]
    /// Same ranges as the children; size desc, ties by name bytes.
    public let childOrder: [Int32]
    /// Inclusive running sums of child sizes over `childOrder`, per child range.
    public let childPrefix: [UInt64]
    public let linkGroups: [HardLinkGroup]

    private static let versions = Atomic<UInt64>(0)

    /// A fresh, process-unique version (every tree, including each partial snapshot and each cache load, gets one).
    public static func nextVersion() -> UInt64 {
        versions.add(1, ordering: .relaxed).newValue
    }

    public init(
        root: ScanRoot, volumeUUID: UUID?, dev: Int32, scanDate: Date, lastEventId: UInt64,
        parent: [Int32], firstChild: [Int32], childCount: [Int32], allocBytes: [UInt64], smallBytes: [UInt64],
        smallCount: [UInt32], fileID: [UInt64], mtime: [Int64], subtreeMaxMtime: [Int64], addedTime: [Int64],
        flags: [StorageNodeFlags], markerMask: [StorageMarker], nameOffset: [UInt32], nameLength: [UInt16],
        names: [UInt8], childOrder: [Int32], childPrefix: [UInt64], linkGroups: [HardLinkGroup],
        version: UInt64 = StorageTree.nextVersion()
    ) {
        let n = parent.count
        precondition(
            [firstChild.count, childCount.count, allocBytes.count, smallBytes.count, smallCount.count,
             fileID.count, mtime.count, subtreeMaxMtime.count, addedTime.count, flags.count, markerMask.count,
             nameOffset.count, nameLength.count, childOrder.count, childPrefix.count].allSatisfy { $0 == n },
            "StorageTree arrays differ in length"
        )
        self.version = version
        self.root = root
        self.volumeUUID = volumeUUID
        self.dev = dev
        self.scanDate = scanDate
        self.lastEventId = lastEventId
        self.parent = parent
        self.firstChild = firstChild
        self.childCount = childCount
        self.allocBytes = allocBytes
        self.smallBytes = smallBytes
        self.smallCount = smallCount
        self.fileID = fileID
        self.mtime = mtime
        self.subtreeMaxMtime = subtreeMaxMtime
        self.addedTime = addedTime
        self.flags = flags
        self.markerMask = markerMask
        self.nameOffset = nameOffset
        self.nameLength = nameLength
        self.names = names
        self.childOrder = childOrder
        self.childPrefix = childPrefix
        self.linkGroups = linkGroups
    }

    public var nodeCount: Int { parent.count }

    public func nameBytes(_ node: StorageNodeID) -> ArraySlice<UInt8> {
        let start = Int(nameOffset[Int(node)])
        return names[start ..< start + Int(nameLength[Int(node)])]
    }

    public func name(_ node: StorageNodeID) -> String {
        String(decoding: nameBytes(node), as: UTF8.self)
    }

    /// Absolute path: the root path plus the names below it.
    public func path(_ node: StorageNodeID) -> String {
        var components: [String] = []
        var n = node
        while n != 0 {
            components.append(name(n))
            n = parent[Int(n)]
        }
        guard !components.isEmpty else { return root.path }
        let base = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        return base + "/" + components.reversed().joined(separator: "/")
    }

    /// Rolled-up allocated bytes; nil when the node is restricted (unknown, not 0).
    public func size(_ node: StorageNodeID) -> UInt64? {
        flags[Int(node)].contains(.restricted) ? nil : allocBytes[Int(node)]
    }

    public func identity(_ node: StorageNodeID) -> FileIdentity {
        FileIdentity(dev: dev, ino: fileID[Int(node)], isDirectory: flags[Int(node)].contains(.directory))
    }

    /// Children by size, largest first (ties by name).
    public func sortedChildren(_ node: StorageNodeID) -> ArraySlice<Int32> {
        let start = Int(firstChild[Int(node)])
        return childOrder[start ..< start + Int(childCount[Int(node)])]
    }

    /// True if `ancestor` is a proper ancestor of `node` (a node is not its own ancestor).
    public func isAncestor(_ ancestor: StorageNodeID, of node: StorageNodeID) -> Bool {
        var n = node
        // parent < child, so the walk can stop as soon as it passes below `ancestor`'s id.
        while n > ancestor {
            n = parent[Int(n)]
            if n == ancestor { return true }
        }
        return false
    }

    public func depth(_ node: StorageNodeID) -> Int {
        var d = 0
        var n = node
        while n != 0 {
            n = parent[Int(n)]
            d += 1
        }
        return d
    }

    /// Node at an absolute path under the root, matched by exact name bytes per component. A trailing slash, an
    /// empty or `.`/`..` component, or a path outside the root gives nil.
    public func lookup(path: String) -> StorageNodeID? {
        if path.utf8.elementsEqual(root.path.utf8) { return 0 }
        let rootComponents = root.path.split(separator: "/", omittingEmptySubsequences: true)
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "", parts.count > rootComponents.count else { return nil }
        for (i, rc) in rootComponents.enumerated() where !parts[i + 1].utf8.elementsEqual(rc.utf8) {
            return nil
        }
        var node: StorageNodeID = 0
        for component in parts.dropFirst(rootComponents.count + 1) {
            guard !component.isEmpty, component != ".", component != ".." else { return nil }
            let start = Int(firstChild[Int(node)])
            guard let child = (start ..< start + Int(childCount[Int(node)])).first(where: {
                nameBytes(Int32($0)).elementsEqual(component.utf8)
            }) else { return nil }
            node = Int32(child)
        }
        return node
    }

    /// Number of children (in `sortedChildren` order) at or above `minFraction` × the node's size: the first child
    /// below the threshold starts the "N smaller items" remainder.
    public func cutoff(_ node: StorageNodeID, minFraction: Double) -> Int {
        let sorted = sortedChildren(node)
        let threshold = Double(allocBytes[Int(node)]) * minFraction
        var lo = sorted.startIndex
        var hi = sorted.endIndex
        while lo < hi {
            let mid = (lo + hi) / 2
            if Double(allocBytes[Int(sorted[mid])]) < threshold { hi = mid } else { lo = mid + 1 }
        }
        return lo - sorted.startIndex
    }

    /// Bytes of the sorted children from position `cut` to the end (folded small files not included).
    public func remainderBytes(_ node: StorageNodeID, from cut: Int) -> UInt64 {
        let start = Int(firstChild[Int(node)])
        let count = Int(childCount[Int(node)])
        guard cut < count else { return 0 }
        let total = childPrefix[start + count - 1]
        return cut <= 0 ? total : total - childPrefix[start + cut - 1]
    }
}
