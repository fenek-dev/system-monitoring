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

    /// Bug: an unreadable dir shows "0 B" as if it were measured, or its folded bytes leak into the parent.
    @Test func restrictedChildHasNoSizeAndContributesNothing() {
        var b = Self.builder()
        let r = b.appendChildren(of: 0, [Self.dir("R"), Self.file("f", 4)]).lowerBound
        b.setRestricted(r)
        b.addSmall(r, bytes: 100, count: 1, maxMtime: 0)
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

    /// Bug: hard-link bytes counted at every link, or at whichever link a worker saw first.
    @Test func hardLinkCreditedOnceAtLowestDepthWhateverTheOrder() {
        for reversed in [false, true] {
            var b = Self.builder()
            let top = b.appendChildren(of: 0, [Self.dir("deep"), Self.file("shallow", 0)])
            let mid = b.appendChildren(of: top.lowerBound, [Self.dir("m")]).lowerBound
            let deepFile = b.appendChildren(of: mid, [Self.file("link", 0)]).lowerBound
            let shallow = top.lowerBound + 1
            let identity = FileIdentity(dev: 1, ino: 42, isDirectory: false)
            let order = reversed ? [shallow, deepFile] : [deepFile, shallow]
            for occ in order { b.addLink(identity, linkCount: 2, bytes: 64, occurrence: occ) }
            let tree = Self.finalize(b)
            #expect(tree.size(shallow) == 64)
            #expect(tree.size(deepFile) == 0)
            #expect(tree.size(0) == 64)
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
