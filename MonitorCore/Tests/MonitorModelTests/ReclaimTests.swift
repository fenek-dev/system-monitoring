import Foundation
import Testing
@testable import MonitorModel

/// Hard links across cleanup items: bytes count once, and only when every link of the file is in the selection.
@Suite struct ReclaimTests {
    typealias T = StorageTreeTests

    static func item(_ id: Int32, node: StorageNodeID, privateBytes: UInt64, groups: [Int32]) -> CleanupItem {
        CleanupItem(id: id, nodeID: node, path: "/p/\(id)", name: "\(id)", category: .developer, tier: .safe,
                    mode: .remove, identity: nil, allocBytes: 0, privateBytesExcludingLinks: privateBytes,
                    linkGroupIndices: groups, sizeProvenance: .exact)
    }

    /// Dirs A, B each hold one link of a 2-link file (group 0, private 100 exact); C holds both links of another
    /// (group 1, same dir); D holds one link of a file whose other link is outside the scan (group 2); E, F hold the
    /// two observed links of a file whose link count rose to 3 during the scan (group 3).
    static func setup() -> (StorageTree, [CleanupItem], a: StorageNodeID) {
        var b = T.builder()
        let dirs = b.appendChildren(of: 0, ["A", "B", "C", "D", "E", "F"].map { T.dir($0) })
        let d = { (i: Int32) in dirs.lowerBound + i }
        let fa = b.appendChildren(of: d(0), [T.file("x", 0)]).lowerBound
        let fb = b.appendChildren(of: d(1), [T.file("y", 0)]).lowerBound
        let ids = (10 ... 13).map { FileIdentity(dev: 1, ino: $0, isDirectory: false) }
        b.addLink(ids[0], linkCount: 2, bytes: 4096, occurrence: fa, privateBytes: 100)
        b.addLink(ids[0], linkCount: 2, bytes: 4096, occurrence: fb, privateBytes: 100)
        b.addLink(ids[1], linkCount: 2, bytes: 50, occurrence: d(2), privateBytes: 50)
        b.addLink(ids[1], linkCount: 2, bytes: 50, occurrence: d(2), privateBytes: 50)
        b.addLink(ids[2], linkCount: 2, bytes: 70, occurrence: d(3), privateBytes: 70)
        b.addLink(ids[3], linkCount: 2, bytes: 80, occurrence: d(4), privateBytes: 80)
        b.addLink(ids[3], linkCount: 3, bytes: 80, occurrence: d(5), privateBytes: 80)
        let tree = T.finalize(b)
        let items = [
            item(1, node: d(0), privateBytes: 10, groups: [0]),
            item(2, node: d(1), privateBytes: 20, groups: [0]),
            item(3, node: d(2), privateBytes: 5, groups: [1]),
            item(4, node: d(3), privateBytes: 1, groups: [2]),
            item(5, node: d(4), privateBytes: 0, groups: [3]),
            item(6, node: d(5), privateBytes: 0, groups: [3]),
        ]
        return (tree, items, d(0))
    }

    /// Bug: a file with a link outside the scan, or whose link count rose while scanning (2 → 3), is reported as
    /// reclaimable although deleting the observed links frees nothing.
    @Test func linksOutsideTheSelectionNeverCount() throws {
        let (tree, items, _) = Self.setup()
        var acc = try ReclaimAccumulator(items: items, tree: tree)
        acc.insert(4)
        #expect(acc.bytes == 1)
        acc.insert(5)
        acc.insert(6)
        #expect(acc.bytes == 1)
    }

    /// Bug: a file linked from two selected items is double counted, or never counted.
    @Test func linksSplitAcrossItemsCountOnceWhenBothSelected() throws {
        let (tree, items, _) = Self.setup()
        var acc = try ReclaimAccumulator(items: items, tree: tree)
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
    @Test func sameDirLinksCountOnce() throws {
        let (tree, items, _) = Self.setup()
        var acc = try ReclaimAccumulator(items: items, tree: tree)
        acc.insert(3)
        #expect(acc.bytes == 55)
    }

    /// Bug: after A was permanently deleted, B's remaining link never becomes reclaimable; or a link sitting in
    /// the Trash (still pinning the blocks) is treated as gone.
    @Test(arguments: [(StorageTreeOverlay.RemovalKind.deleted, UInt64(120)), (.trashed, UInt64(20))])
    func deletedLinksLowerTheRequiredCountTrashedOnesDont(_ kind: StorageTreeOverlay.RemovalKind,
                                                          expected: UInt64) throws {
        let (tree, items, a) = Self.setup()
        var overlay = StorageTreeOverlay(tree: tree)
        try overlay.remove(a, kind: kind, in: tree)
        var acc = try ReclaimAccumulator(items: items, tree: tree, overlay: overlay)
        acc.insert(2)
        #expect(acc.bytes == expected)
    }

    /// Bug: allocated bytes of a link group reported as exact, or exact private bytes ignored.
    @Test(arguments: [
        (LinkGroupSize(privateBytes: 7, provenance: .exact), UInt64(37), SizeProvenance.exact),
        (LinkGroupSize(privateBytes: nil, provenance: .unavailable), UInt64(4126), .unavailable),
        (LinkGroupSize(privateBytes: 7, provenance: .estimate), UInt64(4126), .estimate),
    ])
    func linkGroupBytesAreExactOnlyFromPrivateSize(_ size: LinkGroupSize, expected: UInt64,
                                                  provenance: SizeProvenance) throws {
        let (tree, items, _) = Self.setup()
        var acc = try ReclaimAccumulator(items: items, tree: tree, linkSizes: [0: size])
        acc.insert(1)
        acc.insert(2)
        #expect(acc.bytes == expected)
        #expect(acc.provenance == provenance)
    }

    /// Bug: totals saturate at UInt64.max, so deselecting afterwards returns a wrong number.
    @Test func deselectAfterOverflowIsExact() throws {
        let (tree, _, _) = Self.setup()
        let items = [Self.item(1, node: 1, privateBytes: .max, groups: []),
                     Self.item(2, node: 2, privateBytes: .max, groups: []),
                     Self.item(3, node: 3, privateBytes: 10, groups: [])]
        var acc = try ReclaimAccumulator(items: items, tree: tree)
        for id: Int32 in [1, 2, 3] { acc.insert(id) }
        #expect(acc.bytes == .max)
        acc.remove(1)
        #expect(acc.bytes == .max)
        acc.remove(2)
        #expect(acc.bytes == 10)
    }
}
