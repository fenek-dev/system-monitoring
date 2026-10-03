import Foundation
import Testing
@testable import MonitorModel

/// Hard links across cleanup items: bytes count once, and only when every link is in the selection.
@Suite struct ReclaimTests {
    typealias T = StorageTreeTests

    static func item(_ id: Int32, node: StorageNodeID, privateBytes: UInt64, groups: [Int32]) -> CleanupItem {
        CleanupItem(id: id, nodeID: node, path: "/p/\(id)", name: "\(id)", category: .developer, tier: .safe,
                    mode: .remove, identity: nil, allocBytes: 0, privateBytesExcludingLinks: privateBytes,
                    linkGroupIndices: groups, sizeProvenance: .exact)
    }

    /// Dirs A, B each hold one link of a 2-link file (group 0); C holds both links of another (group 1, same dir);
    /// D holds one link of a file whose other link is outside the scan (group 2).
    static func setup() -> (StorageTree, [CleanupItem]) {
        var b = T.builder()
        let dirs = b.appendChildren(of: 0, [T.dir("A"), T.dir("B"), T.dir("C"), T.dir("D")])
        let (a, bb, c, d) = (dirs.lowerBound, dirs.lowerBound + 1, dirs.lowerBound + 2, dirs.lowerBound + 3)
        let fa = b.appendChildren(of: a, [T.file("x", 0)]).lowerBound
        let fb = b.appendChildren(of: bb, [T.file("y", 0)]).lowerBound
        let g0 = FileIdentity(dev: 1, ino: 10, isDirectory: false)
        let g1 = FileIdentity(dev: 1, ino: 11, isDirectory: false)
        let g2 = FileIdentity(dev: 1, ino: 12, isDirectory: false)
        b.addLink(g0, linkCount: 2, bytes: 100, occurrence: fa)
        b.addLink(g0, linkCount: 2, bytes: 100, occurrence: fb)
        b.addLink(g1, linkCount: 2, bytes: 50, occurrence: c)
        b.addLink(g1, linkCount: 2, bytes: 50, occurrence: c)
        b.addLink(g2, linkCount: 2, bytes: 70, occurrence: d)
        let tree = T.finalize(b)
        let items = [
            item(1, node: a, privateBytes: 10, groups: [0]),
            item(2, node: bb, privateBytes: 20, groups: [0]),
            item(3, node: c, privateBytes: 5, groups: [1]),
            item(4, node: d, privateBytes: 1, groups: [2]),
        ]
        return (tree, items)
    }

    /// Bug: a file with a link outside the scan is reported as reclaimable (deleting one link frees nothing).
    @Test func linkOutsideScanNeverCounts() {
        let (tree, items) = Self.setup()
        var acc = ReclaimAccumulator(items: items, tree: tree)
        acc.insert(4)
        #expect(acc.bytes == 1)
    }

    /// Bug: a file linked from two selected items is double counted, or never counted.
    @Test func linksSplitAcrossItemsCountOnceWhenBothSelected() {
        let (tree, items) = Self.setup()
        var acc = ReclaimAccumulator(items: items, tree: tree)
        acc.insert(1)
        #expect(acc.bytes == 10)
        acc.insert(2)
        #expect(acc.bytes == 130)
        acc.insert(2)                                                  // repeated insert: no change
        #expect(acc.bytes == 130)
        acc.remove(1)
        #expect(acc.bytes == 20)
        acc.remove(2)
        #expect(acc.bytes == 0)
    }

    /// Bug: two links folded into the same dir count twice.
    @Test func sameDirLinksCountOnce() {
        let (tree, items) = Self.setup()
        var acc = ReclaimAccumulator(items: items, tree: tree)
        acc.insert(3)
        #expect(acc.bytes == 55)
    }
}
