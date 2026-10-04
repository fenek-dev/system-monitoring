import Foundation
import Testing
import MonitorModel
@testable import MonitorLive

@MainActor
@Suite struct StorageModelTests {
    let fx = StorageFixture.make()
    let harness = StorageHarness()

    func model(_ items: [CleanupItem], root: String = "/Users/t",
               loadCached: (@MainActor @Sendable (ScanRoot, ClassifyOptions) async
                   -> (StorageTree, StorageTreeOverlay, CleanupSet)?)? = nil,
               summary: StorageSummary? = nil) -> StorageModel {
        let m = StorageModel(actions: harness.actions(loadCached: loadCached, summary: summary), home: root,
                             now: { Date(timeIntervalSince1970: 5_000) })
        if loadCached == nil {
            m.adopt(tree: fx.tree, overlay: StorageTreeOverlay(tree: fx.tree), cleanup: fx.set(items))
        }
        return m
    }

    func outcome(_ id: Int32, bytes: UInt64 = 0, removed: [StorageNodeID] = [], skippedChildren: Int = 0,
                 skip: SkipReason? = nil) -> CleanItemOutcome {
        CleanItemOutcome(itemID: id, detachedBytes: bytes, removedNodes: removed,
                         committedChildren: removed.count, skippedChildren: skippedChildren,
                         partial: skippedChildren > 0 && !removed.isEmpty, skip: skip)
    }

    /// Bug: the footer drifts from the real selection (a missed `remove` on uncheck, or a hard-linked file
    /// subtracted twice when one of its links is cleaned or restored).
    @Test func footerAlwaysEqualsFreshAccumulator() async throws {
        let linkA = fx.item(1, node: fx.a, mode: .trash, privateBytes: 10, groups: [0])
        let linkB = fx.item(2, node: fx.b, privateBytes: 20, groups: [0])
        let other = fx.item(3, node: fx.d)
        let m = model([linkA, linkB, other])
        func check(_ step: String) throws {
            let want = try expectedSelection(m)
            #expect(m.cleanup.selectedBytes == want.bytes, "\(step)")
            #expect(m.cleanup.selectedProvenance == want.provenance, "\(step)")
            #expect(m.cleanup.selectedCount == want.count, "\(step)")
        }
        try check("defaults")
        #expect(m.cleanup.selectedBytes == 10 + 20 + 100 + 500)

        m.cleanup.toggle(.item(1))
        try check("uncheck link A")
        #expect(m.cleanup.selectedBytes == 20 + 500)
        m.cleanup.toggle(.item(1))
        try check("recheck link A")

        #expect(m.clean([linkA]))
        m.apply(.item(outcome(1, removed: [fx.a])))
        try check("link A trashed")
        let record = UndoRecord(date: Date(timeIntervalSince1970: 0), entries: [])
        m.apply(.finished(CleanReport(undo: record)))
        harness.cleanStream.continuation.finish()
        await m.cleanTask?.value
        #expect(m.cleanup.items.map(\.id) == [2, 3])

        #expect(m.undoLast())
        m.apply(.restored(itemID: 1, finalPath: "/Users/t/A"))
        try check("link A restored")
        #expect(m.cleanup.items.map(\.id).sorted() == [1, 2, 3])
        #expect(!m.cleanup.checked.contains(1))
    }

    /// Bug: a keep-parent clean with a skipped child drops the row although data is still on disk, or subtracts the
    /// removed child's bytes twice from the parent.
    @Test func keepParentPartialStaysListedAndShrinksOnce() throws {
        let cache = fx.item(1, node: fx.c, keepParent: true)
        let m = model([cache])
        #expect(m.clean([cache]))
        m.apply(.item(outcome(1, bytes: 30, removed: [fx.c1], skippedChildren: 1)))

        let overlay = try #require(m.spaceMap.overlay)
        #expect(m.cleanup.items.map(\.id) == [1])
        #expect(m.cleanup.items[0].allocBytes == 50)
        #expect(!m.cleanup.checked.contains(1))
        #expect(try !overlay.isRemoved(fx.c, in: fx.tree))
        #expect(try overlay.isRemoved(fx.c1, in: fx.tree))
        #expect(try overlay.size(fx.c, in: fx.tree) == 50)
        #expect(m.spaceMap.children(of: fx.c).map(\.name) == ["c2"])
    }

    /// Bug: a rescan blanks the map with a partial tree, loses the previous tree on failure, or shows a
    /// classification of an older tree.
    @Test func rescanKeepsPreviousTreeAndIgnoresStaleClassification() {
        let m = model([fx.item(1, node: fx.d)])
        m.startScan()
        #expect(m.phase == .scanning(hasPrevious: true))
        let partial = StorageFixture.make().tree
        m.apply(.partial(partial))
        #expect(m.spaceMap.tree === fx.tree)

        var stale = fx.set([fx.item(9, node: fx.e)])
        stale.treeVersion = partial.version
        m.apply(.classified(stale))
        #expect(m.cleanup.items.map(\.id) == [1])

        m.apply(.failed(.io("boom")))
        #expect(m.phase == .failed(.io("boom")))
        #expect(m.spaceMap.tree === fx.tree)
        #expect(m.cleanup.items.map(\.id) == [1])
    }

    @Test func firstScanShowsPartialTrees() {
        let m = StorageModel(actions: harness.actions(), home: "/Users/t")
        m.startScan()
        #expect(m.phase == .scanning(hasPrevious: false))
        m.apply(.partial(fx.tree))
        #expect(m.spaceMap.tree === fx.tree)
        #expect(m.spaceMap.overlay == nil)
    }

    /// Bug: a second classification pass (ownership resolved, new item ids) resets the user's checkboxes.
    @Test func reclassifyKeepsChoicesByPath() {
        let m = model([fx.item(1, node: fx.d), fx.item(2, node: fx.e)])
        m.cleanup.toggle(.item(1))
        #expect(m.cleanup.checked == [2])
        m.apply(.classified(fx.set([fx.item(11, node: fx.d), fx.item(12, node: fx.e),
                                    fx.item(13, node: fx.a)])))
        #expect(m.cleanup.checked == [12, 13])
    }

    /// Bug: a group checkbox checks rows that cannot be cleaned, or rows jump around between rebuilds.
    @Test func groupedRowsTotalsAndToggle() {
        let app = OwnerApp(bundleID: "com.x", name: "X")
        let items = [
            fx.item(1, node: fx.d, bytes: 500, owner: app),
            fx.item(2, node: fx.e, bytes: 700, owner: app),
            fx.item(3, node: fx.a, name: "info", mode: .none, bytes: 50, owner: app),
            fx.item(4, node: fx.b, bytes: 600, owner: OwnerApp(bundleID: "com.y", name: "Y")),
            fx.item(5, node: fx.c, bytes: 600),
        ]
        let m = model(items)
        let group = CleanupLineID.group(.userCaches, bundleID: "com.x")
        // Group 1250 first; the two 600-byte rows tie and fall back to name ("B" before "C").
        #expect(m.cleanup.lines().map(\.id) == [group, .item(4), .item(5)])
        #expect(m.cleanup.lines()[0].bytes == 1250)
        #expect(m.cleanup.lines()[0].childCount == 3)

        m.cleanup.expanded = [group]
        #expect(m.cleanup.lines().map(\.id) == [group, .item(2), .item(1), .item(3), .item(4), .item(5)])
        #expect(m.cleanup.lines().map(\.depth) == [0, 1, 1, 1, 0, 0])

        #expect(m.cleanup.checkState(group) == .on)
        m.cleanup.toggle(.item(1))
        #expect(m.cleanup.checkState(group) == .mixed)
        m.cleanup.toggle(group)
        #expect(m.cleanup.checked == [1, 2, 4, 5])
        #expect(!m.cleanup.checked.contains(3))
        #expect(m.cleanup.checkState(group) == .on)
        m.cleanup.toggle(group)
        #expect(m.cleanup.checked == [4, 5])
    }

    /// Bug: toggling a checkbox rebuilds the row list (checked state leaked into the cache key).
    @Test func toggleDoesNotRebuildLines() {
        let m = model([fx.item(1, node: fx.d), fx.item(2, node: fx.e)])
        let before = m.cleanup.lines()
        m.cleanup.toggle(.item(1))
        #expect(m.cleanup.lines() == before)
        #expect(m.cleanup.checkState(.item(1)) == .off)
    }

    /// Bug: a page switch cancels the running scan; a window close leaks the tree or skips an engine release.
    @Test func lifetimes() async throws {
        let summary = StorageSummary(root: .home("/Users/t"), scanDate: Date(timeIntervalSince1970: 1),
                                     reclaimableBytes: 7, provenance: .exact, trashBytes: nil)
        let m = model([], summary: summary)
        await m.windowDidOpen()
        m.startScan()
        m.pageDidDisappear()
        harness.scanStream.continuation.yield(.progress(ScanProgress(files: 3, bytes: 4, currentPath: "/x")))
        harness.scanStream.continuation.yield(.finished(fx.tree))
        harness.scanStream.continuation.finish()
        await m.scanTask?.value
        #expect(m.spaceMap.tree === fx.tree)
        #expect(m.phase == .ready)
        #expect(harness.cancelScan.value == 0)

        let d = fx.item(1, node: fx.d)
        m.apply(.classified(fx.set([d])))
        m.startScan()
        #expect(m.clean([d]))
        let before = m.summary
        #expect(before?.reclaimableBytes == 500)
        m.windowDidClose()
        #expect(harness.cancelScan.value == 1)
        #expect(harness.cancelClean.value == 1)
        #expect(harness.release.value == 1)
        #expect(m.spaceMap.tree == nil)
        #expect(m.cleanup.items.isEmpty)
        #expect(m.phase == .idle)
        #expect(m.summary == before)
    }

    /// Bug: a cache load that finishes after the window closed resurrects the released tree.
    @Test func lateCacheLoadAfterCloseIsDropped() async {
        let (entered, enteredCont) = AsyncStream<Void>.makeStream()
        let (gate, gateCont) = AsyncStream<Void>.makeStream()
        let tree = fx.tree
        let set = fx.set([fx.item(1, node: fx.d)])
        let m = model([], loadCached: { _, _ in
            enteredCont.yield()
            for await _ in gate { break }
            return (tree, StorageTreeOverlay(tree: tree), set)
        })
        let appear = Task { await m.pageDidAppear() }
        for await _ in entered { break }
        #expect(m.phase == .loadingCache)
        m.windowDidClose()
        gateCont.yield()
        await appear.value
        #expect(m.spaceMap.tree == nil)
        #expect(m.cleanup.items.isEmpty)
        #expect(m.phase == .idle)
    }

    /// Bug: after "Stop", committed items stay listed or the footer stays on "Cleaning".
    @Test func cancelCleanStillAppliesRemainingEvents() async {
        let first = fx.item(1, node: fx.d)
        let second = fx.item(2, node: fx.e)
        let m = model([first, second])
        #expect(m.clean([first, second]))
        #expect(!m.clean([first]))
        m.cancelClean()
        #expect(harness.cancelClean.value == 1)
        let cont = harness.cleanStream.continuation
        cont.yield(.item(outcome(1, bytes: 500, removed: [fx.d])))
        cont.yield(.item(outcome(2, skip: .cancelled)))
        cont.yield(.finished(CleanReport(freedBytes: 500, cancelled: true)))
        cont.finish()
        await m.cleanTask?.value
        #expect(m.cleanup.items.map(\.id) == [2])
        #expect(m.cleanup.skipped.map(\.item.id) == [2])
        #expect(m.cleanup.skipped.map(\.reason) == [.cancelled])
        #expect(m.cleanup.cleanProgress == nil)
        #expect(m.cleanup.lastReport?.cancelled == true)
        #expect(m.cleanTask == nil)
    }

    /// Bug: the Space Map keeps showing a folder that was just deleted.
    @Test func focusInsideRemovedSubtreeMovesToVisibleAncestor() throws {
        let inner = fx.item(1, node: fx.g)
        let m = model([inner])
        m.spaceMap.drill(fx.h)
        #expect(m.spaceMap.focus == fx.h)
        #expect(m.spaceMap.breadcrumb == [0, fx.f, fx.g, fx.h])
        #expect(m.clean([inner]))
        m.apply(.item(outcome(1, bytes: 40, removed: [fx.g])))
        #expect(m.spaceMap.focus == fx.f)
    }

    /// Bug: a pure progress tick or a checkbox toggle re-renders the whole page (10 Hz redraws).
    @Test func observationIsolation() {
        let m = model([fx.item(1, node: fx.d)])
        m.startScan()
        let spaceMap = observe { _ = m.spaceMap.tree; _ = m.spaceMap.overlay; _ = m.spaceMap.focus }
        let cleanup = observe { _ = m.cleanup.items; _ = m.cleanup.checked; _ = m.cleanup.selectedBytes }
        let phase = observe { _ = m.phase }
        m.apply(.progress(ScanProgress(files: 1, bytes: 2, currentPath: "/a")))
        #expect(spaceMap.value == 0)
        #expect(cleanup.value == 0)
        #expect(phase.value == 0)
        let progress = observe { _ = m.progress.progress }
        m.apply(.progress(ScanProgress(files: 2, bytes: 3, currentPath: "/b")))
        #expect(progress.value == 1)

        let spaceMapAgain = observe { _ = m.spaceMap.tree; _ = m.spaceMap.focus }
        m.cleanup.toggle(.item(1))
        #expect(spaceMapAgain.value == 0)
    }

    /// Bug: the "unavailable simulators" item (no tree node) breaks the overlay or stays listed after cleaning.
    @Test func itemWithoutNodeLeavesOverlayUntouched() throws {
        let sims = fx.item(1, node: nil, name: "Unavailable simulators", category: .developer, mode: .simctl,
                           bytes: 900)
        let m = model([sims])
        let version = try #require(m.spaceMap.overlay).version
        #expect(m.clean([sims]))
        m.apply(.item(outcome(1, bytes: 900)))
        #expect(m.cleanup.items.isEmpty)
        #expect(m.spaceMap.overlay?.version == version)
    }

    /// Bug: "Move to Trash" items collide with classifier ids or are offered for a node that is already gone.
    @Test func trashItemsGetFreshNegativeIdsAndSkipHiddenNodes() throws {
        let d = fx.item(1, node: fx.d)
        let m = model([d])
        let one = try #require(m.trashItem(for: fx.e))
        let two = try #require(m.trashItem(for: fx.e))
        #expect(one.id < 0 && two.id < one.id)
        #expect(one.mode == .trash && one.tier == .review && one.allocBytes == 700)
        #expect(m.trashItem(for: 0) == nil)
        #expect(m.clean([d]))
        m.apply(.item(outcome(1, bytes: 500, removed: [fx.d])))
        #expect(m.trashItem(for: fx.d) == nil)
    }

    /// Bug: cleaning on a non-home root (spec §4.4) or a second concurrent clean is accepted.
    @Test func cleanIsRefusedOffHomeUnlessTrashOnly() async {
        let remove = fx.item(1, node: fx.d)
        let trash = fx.item(2, node: fx.e, mode: .trash)
        let tree = fx.tree
        let set = fx.set([remove, trash])
        let m = model([], loadCached: { _, _ in (tree, StorageTreeOverlay(tree: tree), set) })
        await m.selectRoot(.folder("/Users/t"))
        #expect(m.phase == .ready)
        #expect(!m.clean([remove]))
        #expect(m.clean([trash]))
    }

    /// Bug: the home summary is not recomputed after a clean, or is overwritten by a non-home scan.
    @Test func summaryFollowsHomeCleaning() throws {
        let d = fx.item(1, node: fx.d)
        let e = fx.item(2, node: fx.e)
        let m = model([d, e])
        #expect(m.summary?.reclaimableBytes == 1200)
        #expect(m.clean([d]))
        m.apply(.item(outcome(1, bytes: 500, removed: [fx.d])))
        #expect(m.summary?.reclaimableBytes == 700)
    }

    /// Bug: ignoring a row keeps it counted in the footer.
    @Test func ignoreUnchecksAndRemovesFromTotals() {
        let m = model([fx.item(1, node: fx.d), fx.item(2, node: fx.e)])
        m.ignore(path: "/Users/t/D")
        #expect(m.cleanup.checked == [2])
        #expect(m.cleanup.selectedBytes == 700)
        #expect(m.cleanup.lines().map(\.id) == [.item(2)])
        #expect(m.classifyOptions.ignoredPaths == ["/Users/t/D"])
        m.cleanup.showIgnored = true
        #expect(m.cleanup.lines().map(\.id) == [.item(2), .item(1)])
    }
}
