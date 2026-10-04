import Darwin
import Foundation
import MonitorModel
import Synchronization
import Testing
@testable import MonitorDiskTools

@Suite struct PrivateSizeTests {
    private static let root = "/Users/test"

    private func item(_ path: String, id: Int32 = 0, links: [Int32] = [], allocBytes: UInt64 = 999) -> CleanupItem {
        CleanupItem(id: id, nodeID: nil, path: Self.root + "/" + path, name: path, category: .userCaches, tier: .safe,
                    mode: .trash, identity: nil, allocBytes: allocBytes, linkGroupIndices: links)
    }

    private func tree() -> StorageTree {
        TreeFixture.build([
            TreeFixture.dir("Cache", [TreeFixture.link("shared", ino: 5, linkCount: 2, bytes: 50)]),
            TreeFixture.dir("Elsewhere", [TreeFixture.link("other-link", ino: 5, linkCount: 2, bytes: 50)]),
        ])
    }

    private func run(_ items: [InMemoryLister.Item], paths: [CleanupItem],
                     onList: @escaping @Sendable (String) throws(ListError) -> Void = { _ in }) -> PrivateSizer.Output {
        let lister = InMemoryLister(items, onList: onList)
        return PrivateSizer(lister: lister, rootPath: Self.root).run(items: paths, tree: tree())
    }

    /// Bug: hard-linked files are summed into the item (double counting what other links keep alive) instead of being
    /// reported per group, and clone-shared files pass as exact.
    @Test func linksGoToGroupsAndClonesMakeTheSumAnEstimate() {
        let output = run([
            .dir("Cache", [
                .file("plain", 100, privateBytes: 100),
                .file("clone", 100, privateBytes: 0),
                .file("shared", 50, linkCount: 2, fileID: 5, privateBytes: 50),
            ]),
        ], paths: [item("Cache", links: [0])])
        #expect(output.items[0].privateBytesExcludingLinks == 100)
        #expect(output.items[0].sizeProvenance == .estimate)
        #expect(output.linkGroupSizes == [0: LinkGroupSize(privateBytes: 50, provenance: .exact)])
    }

    /// Bug: a clean item (nothing shared) is reported as an estimate, or its size is not replaced by the private sum.
    @Test func fullyPrivateFilesAreExact() {
        let output = run([.dir("Cache", [.file("a", 100, privateBytes: 100), .file("b", 40, privateBytes: 40)])],
                         paths: [item("Cache")])
        #expect(output.items[0].privateBytesExcludingLinks == 140)
        #expect(output.items[0].sizeProvenance == .exact)
    }

    /// Bug: a listing without the private-size bit is trusted as exact, or an unreadable subtree leaves a wrong size.
    @Test func missingBitAndUnreadableSubtreesFallBackToAllocated() {
        let missing = run([.dir("Cache", [.file("a", 100)])], paths: [item("Cache")])
        #expect(missing.items[0].privateBytesExcludingLinks == 100)
        #expect(missing.items[0].sizeProvenance == .estimate)

        let unreadable = run([.dir("Cache", [.dir("locked", [.file("x", 100, privateBytes: 100)])])],
                             paths: [item("Cache", allocBytes: 777)]) { path throws(ListError) in
            if path == "Cache/locked" { throw ListError(errno: EACCES, op: "test") }
        }
        #expect(unreadable.items[0].privateBytesExcludingLinks == nil)
        #expect(unreadable.items[0].sizeProvenance == .estimate)
        #expect(unreadable.items[0].allocBytes == 777)
    }

    /// Bug: a single-file item (Large & Old) is walked as a directory and reports nothing.
    @Test func singleFileItem() {
        let output = run([.file("big.bin", 500, privateBytes: 500)], paths: [item("big.bin")])
        #expect(output.items[0].privateBytesExcludingLinks == 500)
        #expect(output.items[0].sizeProvenance == .exact)
    }

    /// Bug: a multi-link inode the scan never grouped (its other links live outside the scan) is reported as an
    /// exact private size although deleting this one link frees nothing certain.
    @Test func ungroupedMultiLinkInodeIsAnEstimate() {
        let output = run([.dir("Cache", [.file("stray", 50, linkCount: 3, fileID: 77, privateBytes: 50)])],
                         paths: [item("Cache")])
        #expect(output.items[0].privateBytesExcludingLinks == 50)
        #expect(output.items[0].sizeProvenance == .estimate)
        #expect(output.linkGroupSizes.isEmpty)
    }

    /// Bug: a link group whose file shares extents (private < allocated) is labelled exact.
    @Test func sharedLinkGroupIsAnEstimate() {
        let output = run([.dir("Cache", [.file("shared", 50, linkCount: 2, fileID: 5, privateBytes: 20)])],
                         paths: [item("Cache", links: [0])])
        #expect(output.linkGroupSizes == [0: LinkGroupSize(privateBytes: 20, provenance: .estimate)])
    }

    /// Bug: the pass downloads placeholders. A dataless item directory is never listed (it is judged from flags
    /// read without opening anything), and everything the pass lists runs with materialization off, restoring the
    /// borrowed thread's policy afterwards.
    @Test func datalessItemIsNeverEnteredAndTheThreadPolicyIsOffDuringThePass() {
        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let seenDuringListing = Mutex<[Int32]>([])
        let lister = InMemoryLister([
            .dir("Cloud", fileFlags: UInt32(SF_DATALESS), [.file("remote", 100, privateBytes: 100)]),
            .dir("Cache", [.file("a", 10, privateBytes: 10)]),
        ]) { _ throws(ListError) in
            seenDuringListing.withLock {
                $0.append(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD))
            }
        }
        let output = PrivateSizer(lister: lister, rootPath: Self.root)
            .run(items: [item("Cloud", id: 0), item("Cache", id: 1)], tree: tree())
        #expect(lister.listedPaths.withLock { $0 } == ["Cache"])
        #expect(output.items[0].privateBytesExcludingLinks == nil)
        #expect(output.items[0].sizeProvenance == .estimate)
        #expect(output.items[1].privateBytesExcludingLinks == 10)
        #expect(seenDuringListing.withLock { $0 } == [Int32(IOPOL_MATERIALIZE_DATALESS_FILES_OFF)])
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == before)
        #expect(lister.rootAcquired.load(ordering: .sequentiallyConsistent) == 1)
        #expect(lister.rootReleased.load(ordering: .sequentiallyConsistent) == 1)
    }

    /// Bug: cancellation is ignored (later items are still walked) or a half-measured item is written back.
    @Test func cancelStopsTheRunAndKeepsHalfMeasuredItemsUnchanged() {
        let cancelled = Mutex(false)
        let lister = InMemoryLister([.dir("A", [.file("a", 10, privateBytes: 10)]),
                                     .dir("B", [.file("b", 10, privateBytes: 10)])]) { path throws(ListError) in
            if path == "A" { cancelled.withLock { $0 = true } }
        }
        let items = [item("A", id: 0), item("B", id: 1)]
        let output = PrivateSizer(lister: lister, rootPath: Self.root).run(items: items, tree: tree()) {
            cancelled.withLock { $0 }
        }
        #expect(output.items == items)
        #expect(lister.listedPaths.withLock { $0 } == ["A"])
    }
}
