import Foundation
import Testing
@testable import MonitorModel

/// Tree: root(/Users/t) → Library → Caches → { app (dir: blob 40, small 10), old 30 }; root → f 20.
@Suite struct StorageOverlayTests {
    struct Fixture {
        let tree: StorageTree
        let library: StorageNodeID, caches: StorageNodeID, app: StorageNodeID, blob: StorageNodeID
        let old: StorageNodeID
    }

    static func fixture() -> Fixture {
        typealias T = StorageTreeTests
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
    @Test func removeShrinksAncestorsAndHidesSubtree() {
        let f = Self.fixture()
        var o = StorageTreeOverlay(treeVersion: f.tree.version)
        o.remove(f.app, in: f.tree)
        o.remove(f.blob, in: f.tree)                                   // already gone with its parent: no-op
        #expect(o.isRemoved(f.blob, in: f.tree))
        #expect(o.size(f.app, in: f.tree) == nil)
        #expect(o.size(f.caches, in: f.tree) == 30)
        #expect(o.size(0, in: f.tree) == 50)
        #expect(!o.isRemoved(f.old, in: f.tree))
    }

    /// Bug: a keep-parent clean drops the cache dir that is still on disk.
    @Test func shrinkKeepsParent() {
        let f = Self.fixture()
        var o = StorageTreeOverlay(treeVersion: f.tree.version)
        o.shrink(f.app, by: 10, in: f.tree)
        #expect(!o.isRemoved(f.app, in: f.tree))
        #expect(o.size(f.app, in: f.tree) == 40)
        #expect(o.size(f.library, in: f.tree) == 70)
        #expect(o.size(0, in: f.tree) == 90)
    }

    /// Bug: undo leaves the restored item's bytes missing from its ancestors.
    @Test func restoreToOriginalPathReturnsNodeAndBytes() {
        let f = Self.fixture()
        var o = StorageTreeOverlay(treeVersion: f.tree.version)
        o.remove(f.old, in: f.tree)
        o.restore(RestoredEntry(parent: f.caches, name: "old", bytes: 30, itemID: 7), originalNode: f.old, in: f.tree)
        #expect(o.size(f.old, in: f.tree) == 30)
        #expect(o.size(0, in: f.tree) == 100)
        #expect(o.restored.isEmpty)
    }

    /// Bug: an item restored under a new name ("(restored)") is invisible or replaces the original node.
    @Test func restoreUnderNewNameAddsEntry() {
        let f = Self.fixture()
        var o = StorageTreeOverlay(treeVersion: f.tree.version)
        o.remove(f.old, in: f.tree)
        let entry = RestoredEntry(parent: f.caches, name: "old (restored)", bytes: 30, itemID: 7)
        o.restore(entry, originalNode: f.old, in: f.tree)
        #expect(o.isRemoved(f.old, in: f.tree))
        #expect(o.restoredEntries(under: f.caches) == [entry])
        #expect(o.size(f.caches, in: f.tree) == 80)
        #expect(o.size(0, in: f.tree) == 100)
    }

    /// Bug: negative / wrapped totals after over-reported partial removals and clean + undo.
    @Test func sizesSaturateAtZero() {
        let f = Self.fixture()
        var o = StorageTreeOverlay(treeVersion: f.tree.version)
        o.shrink(f.app, by: 500, in: f.tree)
        #expect(o.size(f.app, in: f.tree) == 0)
        #expect(o.size(f.caches, in: f.tree) == 30)
        #expect(o.size(0, in: f.tree) == 50)
        o.remove(f.app, in: f.tree)
        #expect(o.size(0, in: f.tree) == 50)
    }
}
