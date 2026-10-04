import Foundation
import Testing
@testable import MonitorModel

/// Tree: root(/Users/t) → Library → Caches → { app (dir: blob 40, small 10), old 30 }; root → f 20.
@Suite struct StorageOverlayTests {
    typealias T = StorageTreeTests

    struct Fixture {
        let tree: StorageTree
        let library: StorageNodeID, caches: StorageNodeID, app: StorageNodeID, blob: StorageNodeID
        let old: StorageNodeID
    }

    static func fixture() -> Fixture {
        var b = T.builder()
        let top = b.appendChildren(of: 0, [T.dir("Library"), T.file("f", 20)])
        let caches = b.appendChildren(of: top.lowerBound, [T.dir("Caches")]).lowerBound
        let kids = b.appendChildren(of: caches, [T.dir("app"), T.file("old", 30)])
        let blob = b.appendChildren(of: kids.lowerBound, [T.file("blob", 40)]).lowerBound
        b.addSmall(kids.lowerBound, bytes: 10, count: 3, maxMtime: 0)
        return Fixture(tree: T.finalize(b), library: top.lowerBound, caches: caches, app: kids.lowerBound,
                       blob: blob, old: kids.lowerBound + 1)
    }

    /// Bug: removing a node leaves ancestors at their old size, or its children still show.
    @Test func removeShrinksAncestorsAndHidesSubtree() throws {
        let f = Self.fixture()
        var o = StorageTreeOverlay(tree: f.tree)
        try o.remove(f.app, kind: .deleted, in: f.tree)
        try o.remove(f.blob, kind: .deleted, in: f.tree)                 // already gone with its parent: no-op
        #expect(try o.isRemoved(f.blob, in: f.tree))
        #expect(try o.size(f.app, in: f.tree) == nil)
        #expect(try o.size(f.caches, in: f.tree) == 30)
        #expect(try o.size(0, in: f.tree) == 50)
        #expect(try !o.isRemoved(f.old, in: f.tree))
    }

    /// Bug: a keep-parent clean drops the cache dir that is still on disk.
    @Test func shrinkKeepsParent() throws {
        let f = Self.fixture()
        var o = StorageTreeOverlay(tree: f.tree)
        try o.shrink(f.app, by: 10, in: f.tree)
        #expect(try !o.isRemoved(f.app, in: f.tree))
        #expect(try o.size(f.app, in: f.tree) == 40)
        #expect(try o.size(f.library, in: f.tree) == 70)
        #expect(try o.size(0, in: f.tree) == 90)
    }

    /// Bug: undo leaves the restored item's bytes missing from its ancestors.
    @Test func restoreToOriginalPathReturnsNodeAndBytes() throws {
        let f = Self.fixture()
        var o = StorageTreeOverlay(tree: f.tree)
        try o.remove(f.old, kind: .trashed, in: f.tree)
        try o.restore(RestoredEntry(parent: f.caches, name: "old", bytes: 30, itemID: 7), originalNode: f.old,
                      in: f.tree)
        #expect(try o.size(f.old, in: f.tree) == 30)
        #expect(try o.size(0, in: f.tree) == 100)
        #expect(o.restored.isEmpty)
    }

    /// Bug: an item restored under a new name ("(restored)") is invisible or replaces the original node.
    @Test func restoreUnderNewNameAddsEntry() throws {
        let f = Self.fixture()
        var o = StorageTreeOverlay(tree: f.tree)
        try o.remove(f.old, kind: .trashed, in: f.tree)
        let entry = RestoredEntry(parent: f.caches, name: "old (restored)", bytes: 30, itemID: 7)
        try o.restore(entry, originalNode: f.old, in: f.tree)
        #expect(try o.isRemoved(f.old, in: f.tree))
        #expect(o.restoredEntries(under: f.caches) == [entry])
        #expect(try o.size(f.caches, in: f.tree) == 80)
        #expect(try o.size(0, in: f.tree) == 100)
    }

    /// Bug: undo into a deleted dir leaves the item invisible, revives the deleted siblings, or counts the item
    /// twice — whatever order two items come back in.
    @Test(arguments: [false, true])
    func restoreIntoDeletedParentRecreatesItWithOnlyRestoredItems(_ reversedOrder: Bool) throws {
        var b = T.builder()
        let p = b.appendChildren(of: 0, [T.dir("P"), T.file("f", 5)]).lowerBound
        let kids = b.appendChildren(of: p, [T.file("c1", 30), T.file("c2", 10), T.file("s", 20)])
        let (c1, c2, s) = (kids.lowerBound, kids.lowerBound + 1, kids.lowerBound + 2)
        let tree = T.finalize(b)
        var o = StorageTreeOverlay(tree: tree)
        try o.remove(c1, kind: .trashed, in: tree)
        try o.remove(c2, kind: .trashed, in: tree)
        try o.remove(p, kind: .deleted, in: tree)
        #expect(try o.size(0, in: tree) == 5)
        let entries = [(RestoredEntry(parent: p, name: "c1", bytes: 30, itemID: 1), c1),
                       (RestoredEntry(parent: p, name: "c2", bytes: 10, itemID: 2), c2)]
        for (entry, node) in reversedOrder ? entries.reversed() : entries {
            try o.restore(entry, originalNode: node, in: tree)
        }
        #expect(try o.size(p, in: tree) == 40)
        #expect(try o.size(c1, in: tree) == 30)
        #expect(try o.size(c2, in: tree) == 10)
        #expect(try o.isRemoved(s, in: tree))
        #expect(try o.size(0, in: tree) == 45)
    }

    /// Bug: negative / wrapped totals after over-reported partial removals and clean + undo.
    @Test func sizesSaturateAtZero() throws {
        let f = Self.fixture()
        var o = StorageTreeOverlay(tree: f.tree)
        try o.shrink(f.app, by: 500, in: f.tree)
        #expect(try o.size(f.app, in: f.tree) == 0)
        #expect(try o.size(f.caches, in: f.tree) == 30)
        #expect(try o.size(0, in: f.tree) == 50)
        try o.remove(f.app, kind: .deleted, in: f.tree)
        #expect(try o.size(0, in: f.tree) == 50)
    }

    /// Bug: 64-bit signed deltas clamp sizes above Int64.max, and sums past UInt64.max wrap.
    @Test func byteMathIsExactPastInt64AndUInt64() throws {
        let big = UInt64(Int64.max) + 11
        var b = T.builder()
        let kids = b.appendChildren(of: 0, [T.file("big", big), T.file("one", 1)])
        let tree = T.finalize(b)
        var o = StorageTreeOverlay(tree: tree)
        try o.shrink(kids.lowerBound, by: 5, in: tree)
        #expect(try o.size(kids.lowerBound, in: tree) == big - 5)
        #expect(try o.size(0, in: tree) == big - 4)
        try o.restore(RestoredEntry(parent: 0, name: "huge", bytes: .max, itemID: 1), originalNode: nil, in: tree)
        #expect(try o.size(0, in: tree) == .max)                          // past UInt64.max, clamped on read
        try o.remove(kids.lowerBound, kind: .deleted, in: tree)
        try o.remove(kids.lowerBound + 1, kind: .deleted, in: tree)
        #expect(try o.size(0, in: tree) == .max)                          // exactly UInt64.max: only "huge" left
        try o.shrink(0, by: 1, in: tree)
        #expect(try o.size(0, in: tree) == .max - 1)
    }

    /// Bug: an overlay applied to another tree (or a sidecar to another scan) shifts sizes onto unrelated nodes.
    @Test func rejectsOtherTrees() throws {
        let f = Self.fixture()
        let other = Self.fixture().tree                                  // same scan, new version
        var o = StorageTreeOverlay(tree: f.tree)
        #expect(throws: StorageOverlayError.treeMismatch) { try o.remove(f.old, kind: .deleted, in: other) }
        #expect(throws: StorageOverlayError.treeMismatch) { try o.size(0, in: other) }
        let rebased = try o.rebased(onto: other)
        #expect(try rebased.size(0, in: other) == 100)
        var b = T.builder()
        b.appendChildren(of: 0, [T.file("x", 1)])
        #expect(throws: StorageOverlayError.treeMismatch) { try o.rebased(onto: T.finalize(b)) }
    }

    /// Bug: deleting or trashing the link that holds a hard-linked file's bytes drops them from the map while
    /// another link keeps the file; undo then counts them twice.
    @Test(arguments: [StorageTreeOverlay.RemovalKind.deleted, .trashed])
    func linkBytesMoveToTheNextSurvivingLink(_ kind: StorageTreeOverlay.RemovalKind) throws {
        var b = T.builder()
        let top = b.appendChildren(of: 0, [T.dir("A"), T.dir("B")])
        let (a, bDir) = (top.lowerBound, top.lowerBound + 1)
        let x = b.appendChildren(of: a, [T.file("x", 0)]).lowerBound
        let c = b.appendChildren(of: bDir, [T.dir("C")]).lowerBound
        let y = b.appendChildren(of: c, [T.file("y", 0)]).lowerBound
        let id = FileIdentity(dev: 1, ino: 9, isDirectory: false)
        b.addLink(id, linkCount: 2, bytes: 100, occurrence: y)
        b.addLink(id, linkCount: 2, bytes: 100, occurrence: x)
        let tree = T.finalize(b)
        #expect(tree.size(a) == 100 && tree.size(bDir) == 0)
        var o = StorageTreeOverlay(tree: tree)
        try o.remove(a, kind: kind, in: tree)
        #expect(try o.size(y, in: tree) == 100)
        #expect(try o.size(bDir, in: tree) == 100)
        #expect(try o.size(0, in: tree) == 100)
        guard kind == .trashed else { return }
        try o.restore(RestoredEntry(parent: 0, name: "A", bytes: 100, itemID: 1), originalNode: a, in: tree)
        #expect(try o.size(a, in: tree) == 100)
        #expect(try o.size(bDir, in: tree) == 0)
        #expect(try o.size(0, in: tree) == 100)
    }
}
