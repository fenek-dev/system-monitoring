import Foundation
import Testing
@testable import MonitorModel

@Suite struct StorageTreeTests {
    static func file(_ name: String, _ bytes: UInt64, mtime: Int64 = 0) -> NodeRecord {
        NodeRecord(name: name, flags: [], allocBytes: bytes, fileID: 0, mtime: mtime, addedTime: 0)
    }

    static func dir(_ name: String, flags: StorageNodeFlags = [], mtime: Int64 = 0) -> NodeRecord {
        NodeRecord(name: name, flags: flags.union(.directory), allocBytes: 0, fileID: 0, mtime: mtime, addedTime: 0)
    }

    static func builder() -> StorageTreeBuilder {
        StorageTreeBuilder(root: .home("/Users/t"), dev: 1, volumeUUID: nil)
    }

    static func finalize(_ b: consuming StorageTreeBuilder) -> StorageTree {
        b.finalize(scanDate: Date(timeIntervalSince1970: 0), lastEventId: 0)
    }

    /// Bug: listings committed out of order (grandchildren after an uncle's children) undercount ancestors.
    @Test func rollupCountsGrandchildrenCommittedInLaterBatches() {
        var b = Self.builder()
        let top = b.appendChildren(of: 0, [Self.dir("A"), Self.dir("B"), Self.file("f", 10)])
        let (a, bDir) = (top.lowerBound, top.lowerBound + 1)
        b.appendChildren(of: bDir, [Self.file("b1", 5)])
        let a1 = b.appendChildren(of: a, [Self.dir("a1")]).lowerBound
        b.appendChildren(of: a1, [Self.file("x", 7)])
        b.addSmall(a, bytes: 3, count: 2, maxMtime: 0)
        let tree = Self.finalize(b)
        #expect(tree.size(a1) == 7)
        #expect(tree.size(a) == 10)
        #expect(tree.size(bDir) == 5)
        #expect(tree.size(0) == 25)
    }

    /// Bug: an unreadable dir shows "0 B" as if it were measured, or bytes listed below it leak into its ancestors.
    @Test func restrictedChildHasNoSizeAndContributesNothing() {
        var b = Self.builder()
        let r = b.appendChildren(of: 0, [Self.dir("R"), Self.file("f", 4)]).lowerBound
        b.setRestricted(r)
        b.appendChildren(of: r, [Self.file("inner", 60)])
        b.addSmall(r, bytes: 40, count: 1, maxMtime: 0)
        let tree = Self.finalize(b)
        #expect(tree.size(r) == nil)
        #expect(tree.size(0) == 4)
    }

    /// Bug: sorting by size moves node ids, so hover / cache / cleanup items point at the wrong node.
    @Test func childOrderSortsBySizeThenNameAndKeepsIDs() {
        var b = Self.builder()
        let ids = b.appendChildren(of: 0, [Self.file("b", 5), Self.file("c", 9), Self.file("a", 5)])
        let tree = Self.finalize(b)
        #expect(Array(tree.sortedChildren(0)) == [ids.lowerBound + 1, ids.lowerBound + 2, ids.lowerBound])
        #expect(ids.map { tree.name($0) } == ["b", "c", "a"])
    }

    /// Bug: off-by-one at the "N smaller items" boundary (a child exactly at the threshold is kept).
    @Test(arguments: [
        ([UInt64(90), 5, 3, 2], 0.04, 2, UInt64(5)),
        ([UInt64(80), 32, 16], 0.125, 3, UInt64(0)),
        ([UInt64(80), 32, 16], 0.25, 2, UInt64(16)),
    ])
    func cutoffAndRemainder(sizes: [UInt64], fraction: Double, kept: Int, remainder: UInt64) {
        var b = Self.builder()
        b.appendChildren(of: 0, sizes.enumerated().map { Self.file("f\($0.offset)", $0.element) })
        let tree = Self.finalize(b)
        let cut = tree.cutoff(0, minFraction: fraction)
        #expect(cut == kept)
        #expect(tree.remainderBytes(0, from: cut) == remainder)
    }

    /// Bug: a project with only small fresh files looks stale; a fresh `node_modules` makes a stale project look fresh.
    @Test func subtreeMaxMtimeIncludesFoldedFilesAndSkipsBuildDirs() {
        var b = Self.builder()
        let proj = b.appendChildren(of: 0, [Self.dir("proj", mtime: 100)]).lowerBound
        let kids = b.appendChildren(of: proj, [Self.dir("src", mtime: 100),
                                               Self.dir("node_modules", flags: .buildDir, mtime: 9000)])
        b.addSmall(kids.lowerBound, bytes: 1, count: 1, maxMtime: 5000)
        let tree = Self.finalize(b)
        #expect(tree.subtreeMaxMtime[Int(kids.lowerBound)] == 5000)
        #expect(tree.subtreeMaxMtime[Int(proj)] == 5000)
        #expect(tree.subtreeMaxMtime[0] == 5000)
    }

    /// Bug: hard-link bytes counted at every link, at whichever link a worker saw first, or above a folded link's
    /// real depth (a link folded into `d1` sits at depth 2, like the kept `/a/k`; the path decides: `/a/k` first).
    @Test func hardLinkCreditedOnceAtLowestRealDepthWhateverTheOrder() {
        for reversed in [false, true] {
            var b = Self.builder()
            let top = b.appendChildren(of: 0, [Self.dir("d1"), Self.dir("a"), Self.dir("deep")])
            let (d1, a, deep) = (top.lowerBound, top.lowerBound + 1, top.lowerBound + 2)
            let kept = b.appendChildren(of: a, [Self.file("k", 0)]).lowerBound
            let deeper = b.appendChildren(of: deep, [Self.dir("m")]).lowerBound
            let deepFile = b.appendChildren(of: deeper, [Self.file("link", 0)]).lowerBound
            let identity = FileIdentity(dev: 1, ino: 42, isDirectory: false)
            let order = reversed ? [kept, d1, deepFile] : [deepFile, d1, kept]
            for occ in order { b.addLink(identity, linkCount: 3, bytes: 64, occurrence: occ) }
            let tree = Self.finalize(b)
            #expect(tree.size(kept) == 64)
            #expect(tree.size(d1) == 0)
            #expect(tree.size(deepFile) == 0)
            #expect(tree.size(0) == 64)
            #expect(tree.linkGroups[0].occurrences == [
                LinkOccurrence(node: kept, depth: 2, isFolded: false),
                LinkOccurrence(node: d1, depth: 2, isFolded: true),
                LinkOccurrence(node: deepFile, depth: 3, isFolded: false),
            ])
        }
    }

    @Test func lookupMatchesWholeComponentsOnly() {
        var b = Self.builder()
        let lib = b.appendChildren(of: 0, [Self.dir("Library")]).lowerBound
        let caches = b.appendChildren(of: lib, [Self.dir("Caches")]).lowerBound
        let tree = Self.finalize(b)
        #expect(tree.lookup(path: "/Users/t/Library/Caches") == caches)
        #expect(tree.lookup(path: "/Users/t") == 0)
        #expect(tree.lookup(path: "/Users/t/Library/") == nil)
        #expect(tree.lookup(path: "/Users/t/Library/Logs") == nil)
        #expect(tree.lookup(path: "/Users/tt/Library") == nil)
        #expect(tree.path(caches) == "/Users/t/Library/Caches")
    }
}
