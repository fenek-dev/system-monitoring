import Darwin
import Foundation
import MonitorModel
import Synchronization
import Testing
@testable import MonitorDiskTools

@Suite struct CleanerTests {
    private func run(_ cleaner: Cleaner, _ items: [CleanupItem], _ box: CleanSandbox,
                     tree: StorageTree? = nil) async -> CleanEvents {
        let tree = tree ?? box.tree()
        return await collect(cleaner.clean(items, tree: tree, overlay: StorageTreeOverlay(tree: tree)))
    }

    private func allocated(_ box: CleanSandbox, _ rel: String) -> UInt64 {
        CleanFS.allocatedBytes(dirFd: AT_FDCWD, name: box.path(rel))
    }

    /// Bug: keep-parent removes the parent itself, or only the children the scan knew about.
    @Test func keepParentHandlesLiveListingAndKeepsDirectory() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Caches/app/known.bin", bytes: 8192)
        // Real inodes in the tree, so the scanned node matches the live child; its scanned size is made different
        // from the live one to tell which rule priced it.
        let scannedSize: UInt64 = 777
        let tree = try box.liveTree(sizes: ["Library/Caches/app/known.bin": scannedSize])
        let appNode = try #require(tree.lookup(path: box.path("home/Library/Caches/app")))
        let knownNode = try #require(tree.lookup(path: box.path("home/Library/Caches/app/known.bin")))
        let item = try box.item(1, "home/Library/Caches/app", keepParent: true, node: appNode,
                                identity: tree.identity(appNode))
        // Created after the scan: the tree has no node for these.
        try box.write("home/Library/Caches/app/late.bin", bytes: 4096)
        try box.write("home/Library/Caches/app/lateDir/x", bytes: 4096)
        let liveKnown = allocated(box, "home/Library/Caches/app/known.bin")
        #expect(liveKnown != scannedSize)
        let expectedBytes = scannedSize + allocated(box, "home/Library/Caches/app/late.bin")
            + allocated(box, "home/Library/Caches/app/lateDir")

        let events = await run(Cleaner(context: box.context()), [item], box, tree: tree)

        #expect(box.exists("home/Library/Caches/app"))
        #expect(box.list("home/Library/Caches/app").isEmpty)
        let outcome = try #require(events.finished.first?.outcomes.first)
        #expect(outcome.committedChildren == 3)
        #expect(outcome.skippedChildren == 0)
        #expect(outcome.partial == false)
        #expect(outcome.removedNodes == [knownNode])
        #expect(outcome.detachedBytes == expectedBytes)
        #expect(events.finished.count == 1)
        #expect(events.finished[0].freedBytes == expectedBytes)
        #expect(events.freed.reduce(0, +) == expectedBytes)
    }

    /// Bug: a symlinked path component is followed and the cleaner deletes outside the permitted root.
    @Test func symlinkComponentIsRefusedAndTargetSurvives() async throws {
        let box = try CleanSandbox()
        try box.write("outside/victim/f.txt")
        try box.makeDir("home/Library/Caches")
        #expect(symlink(box.path("outside"), box.path("home/link")) == 0)
        let identity = try box.identity("outside/victim")
        let item = CleanupItem(id: 1, nodeID: nil, path: box.path("home/link/victim"), name: "victim",
                               category: .userCaches, tier: .safe, mode: .remove, identity: identity, allocBytes: 1)

        let events = await run(Cleaner(context: box.context()), [item], box)

        // The no-follow directory open of the `link` component fails (ENOTDIR for a symlink): refused as "changed".
        #expect(events.finished.first?.outcomes.first?.skip == .changedSinceScan)
        #expect(box.list("outside/victim") == ["f.txt"])
        #expect(box.list("staging/pending").isEmpty && box.list("staging/commit").isEmpty)
    }

    /// Bug: a permanent delete is allowed outside the home folder (only Trash may leave it).
    @Test func removeOutsideHomeIsDenied() async throws {
        let box = try CleanSandbox()
        try box.write("other/data/f.txt")
        let item = try box.item(1, "other/data")

        let events = await run(Cleaner(context: box.context(permittedRoot: box.base)), [item], box)

        #expect(events.finished.first?.outcomes.first?.skip == .denied(.removeOutsideHome))
        #expect(box.list("other/data") == ["f.txt"])
    }

    /// Bug: a read-only directory inside a cache tree strands the whole item (EACCES, the entry is not freed).
    @Test(arguments: [true, false])
    func readOnlySubtreeIsDeletedAfterPermissionRepair(slim: Bool) async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Caches/tool/ro/deep/f.bin", bytes: 8192)
        try box.write("home/Library/Caches/tool/ro/g.bin", bytes: 8192)
        #expect(chmod(box.path("home/Library/Caches/tool/ro/deep"), 0o000) == 0)
        #expect(chmod(box.path("home/Library/Caches/tool/ro"), 0o555) == 0)
        let item = try box.item(1, "home/Library/Caches/tool", bytes: 5000)

        let events = await run(Cleaner(context: box.context(deleter: DeleteWorker(slim: slim))), [item], box)

        #expect(!box.exists("home/Library/Caches/tool"))
        #expect(box.list("staging/commit").isEmpty)
        #expect(events.finished.first?.freedBytes == 5000)
        #expect(events.finished.first?.outcomes.first?.partial == false)
    }

    /// Bug: a locked (`uchg`) file survives the delete but the bytes are still credited as freed.
    @Test func immutableFileInCommittedTreeIsPartialAndNotCredited() async throws {
        let box = try CleanSandbox()
        let locked = try box.write("home/Library/Caches/tool/locked.bin")
        try box.write("home/Library/Caches/tool/free.bin")
        #expect(lchflags(locked, UInt32(UF_IMMUTABLE)) == 0)
        let item = try box.item(1, "home/Library/Caches/tool", bytes: 5000)

        let events = await run(Cleaner(context: box.context()), [item], box)

        let report = try #require(events.finished.first)
        #expect(report.freedBytes == 0)
        #expect(events.freed.isEmpty)
        #expect(report.outcomes.first?.partial == true)
        #expect(!box.exists("home/Library/Caches/tool"))
        #expect(box.list("staging/commit").count == 1)
    }

    /// Bug: cancelling before the first item hangs, detaches something, or emits no `.finished`.
    @Test func cancelBeforeFirstItemDetachesNothing() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Caches/a/f")
        try box.write("home/Library/Caches/b/f")
        let items = [try box.item(1, "home/Library/Caches/a"), try box.item(2, "home/Library/Caches/b")]
        let holder = Mutex<Cleaner?>(nil)
        let hooks = CleanTestHooks(beforeItem: { index in if index == 0 { holder.withLock { $0 }?.cancel() } })
        let cleaner = Cleaner(context: box.context(), hooks: hooks)
        holder.withLock { $0 = cleaner }

        let events = await run(cleaner, items, box)

        #expect(events.finished.count == 1)
        #expect(events.finished[0].cancelled)
        #expect(events.finished[0].outcomes.map(\.skip) == [.cancelled, .cancelled])
        #expect(box.exists("home/Library/Caches/a/f") && box.exists("home/Library/Caches/b/f"))
        #expect(events.freed.isEmpty)
    }

    /// Bug: cancelling between items loses entries that are already committed (they must drain and be freed) or
    /// keeps detaching the rest; also exactly one `.finished`.
    @Test func cancelBetweenItemsDrainsCommittedEntries() async throws {
        let box = try CleanSandbox()
        let names = ["a", "b", "c", "d"]
        for name in names { try box.write("home/Library/Caches/\(name)/f") }
        let items = try names.enumerated().map { try box.item(Int32($0.offset), "home/Library/Caches/\($0.element)", bytes: 100) }
        let gated = GatedDeleter(inner: DeleteWorker(slim: false))
        let holder = Mutex<Cleaner?>(nil)
        let hooks = CleanTestHooks(beforeItem: { index in
            guard index == 2 else { return }
            // Items 0 and 1 are committed but their deletes are still blocked on the gate.
            holder.withLock { $0 }?.cancel()
            gated.release(2)
        })
        let cleaner = Cleaner(context: box.context(deleter: gated), hooks: hooks)
        holder.withLock { $0 = cleaner }

        let events = await run(cleaner, items, box)

        #expect(events.finished.count == 1)
        let report = events.finished[0]
        #expect(report.cancelled)
        #expect(report.freedBytes == 200)
        #expect(report.outcomes.map(\.skip) == [nil, nil, .cancelled, .cancelled])
        #expect(!box.exists("home/Library/Caches/a") && !box.exists("home/Library/Caches/b"))
        #expect(box.exists("home/Library/Caches/c/f") && box.exists("home/Library/Caches/d/f"))
    }

    /// Bug: an item that vanished before the clean is reported as a failure (remove) or as success (trash).
    @Test func vanishedItemsFollowModeSemantics() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Caches/gone/f")
        let tree = box.tree([TreeFixture.dir("Library", [TreeFixture.dir("Caches", [
            TreeFixture.dir("gone", [TreeFixture.file("f", 10)]),
        ])])])
        let node = try #require(tree.lookup(path: box.path("home/Library/Caches/gone")))
        let remove = try box.item(1, "home/Library/Caches/gone", node: node)
        var trash = remove
        trash.id = 2
        trash.mode = .trash
        try FileManager.default.removeItem(atPath: box.path("home/Library/Caches/gone"))

        let events = await run(Cleaner(context: box.context()), [remove, trash], box, tree: tree)

        let outcomes = try #require(events.finished.first?.outcomes)
        #expect(outcomes[0].skip == nil)
        #expect(outcomes[0].detachedBytes == 0)
        #expect(outcomes[0].removedNodes == [node])
        #expect(outcomes[1].skip == .vanished)
        #expect(outcomes[1].detachedBytes == 0)
        #expect(outcomes[1].removedNodes.isEmpty)
    }

    /// Bug: with no Trash the cleaner deletes instead.
    @Test func noTrashSkipsAndKeepsFile() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/report.pdf")
        let item = try box.item(1, "home/Documents/report.pdf", mode: .trash)

        let events = await run(Cleaner(context: box.context(trash: NoTrash())), [item], box)

        #expect(events.finished.first?.outcomes.first?.skip == .noTrash)
        #expect(box.exists("home/Documents/report.pdf"))
        #expect(events.finished.first?.trashedBytes == 0)
    }

    /// Bug: Empty Trash stalls on a locked (`uchg`) file, at the top level or inside a folder.
    @Test func emptyTrashRemovesImmutableEntries() async throws {
        let box = try CleanSandbox()
        let topLocked = try box.write("home/.Trash/locked.txt")
        let inner = try box.write("home/.Trash/folder/inner.txt")
        try box.write("home/.Trash/plain.txt")
        #expect(lchflags(topLocked, UInt32(UF_IMMUTABLE)) == 0)
        #expect(lchflags(inner, UInt32(UF_IMMUTABLE)) == 0)

        let events = await collect(Cleaner(context: box.context()).emptyTrash())

        #expect(box.list("home/.Trash").isEmpty)
        #expect(events.finished.count == 1)
        #expect(events.finished[0].outcomes.allSatisfy { $0.skip == nil && !$0.partial })
        #expect(events.finished[0].freedBytes > 0)
        #expect(box.list("staging/commit").isEmpty)
        #expect(events.finished[0].outcomes.compactMap(\.path).sorted()
                == ["folder", "locked.txt", "plain.txt"].map { box.path("home/.Trash/" + $0) })
    }

    /// Bug: freedBytes counts detached or trashed bytes instead of only what was fully removed, or Trash bytes leak
    /// into it; also the undo record carries exactly the trashed entry.
    @Test func freedBytesCountOnlyFullyRemovedItems() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Caches/clean/f")
        let stuck = try box.write("home/Library/Caches/stuck/f")
        try box.write("home/Documents/doc.txt")
        #expect(lchflags(stuck, UInt32(UF_IMMUTABLE)) == 0)
        let items = [
            try box.item(1, "home/Library/Caches/clean", bytes: 1000),
            try box.item(2, "home/Library/Caches/stuck", bytes: 2000),
            try box.item(3, "home/Documents/doc.txt", mode: .trash, bytes: 4000),
        ]

        let events = await run(Cleaner(context: box.context()), items, box)

        let report = try #require(events.finished.first)
        #expect(report.freedBytes == 1000)
        #expect(report.trashedBytes == 4000)
        #expect(report.outcomes.map(\.partial) == [false, true, false])
        #expect(report.undo?.entries.map(\.itemID) == [3])
        #expect(events.freed == [1000])
    }

    /// Bug: the denylist is bypassed when the target is missing from the tree or only protected by live identity.
    @Test func protectedTargetsAreDeniedFromLiveState() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Mail/V10/m.emlx")
        try box.write("appdata/db.sqlite")
        try box.write("home/Library/Caches/ok/f")
        let items = [
            try box.item(1, "home/Library/Mail/V10"),
            try box.item(2, "appdata", mode: .trash),
            try box.item(3, "home/Library/Mail", mode: .trash),
            try box.item(4, "home/Library/Caches/ok"),
        ]

        let events = await run(Cleaner(context: box.context(permittedRoot: box.base)), items, box)

        let skips = try #require(events.finished.first?.outcomes.map(\.skip))
        #expect(skips == [.denied(.protected), .denied(.protected), .denied(.anchor), nil])
        #expect(box.exists("home/Library/Mail/V10/m.emlx") && box.exists("appdata/db.sqlite"))
    }

    /// Bug: an item replaced after the scan is trashed anyway (Trash and evict only have the pre-check).
    @Test func trashRefusesReplacedItem() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/a.txt")
        let stale = try box.identity("home/Documents/a.txt")
        try FileManager.default.removeItem(atPath: box.path("home/Documents/a.txt"))
        try box.write("home/Documents/a.txt")
        let trash = FakeTrash(directory: box.fakeTrash)
        let item = try box.item(1, "home/Documents/a.txt", mode: .trash, identity: stale)

        let events = await run(Cleaner(context: box.context(trash: trash)), [item], box)

        #expect(events.finished.first?.outcomes.first?.skip == .changedSinceScan)
        #expect(trash.calls.withLock { $0 } == 0)
        #expect(box.exists("home/Documents/a.txt"))
    }

    /// Bug: simctl / info-only items touch the filesystem (the simulators' directory must never be touched).
    @Test func simctlUsesRunnerOnlyAndNoneModeIsRefused() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Developer/CoreSimulator/Devices/keep/f")
        let simctl = FakeSimctl()
        let sim = CleanupItem(id: 1, nodeID: nil, path: box.path("home/Library/Developer/CoreSimulator/Devices"),
                              name: "Devices", category: .developer, tier: .review, mode: .simctl, identity: nil,
                              allocBytes: 777)
        var docker = sim
        docker.id = 2
        docker.mode = .none

        let events = await run(Cleaner(context: box.context(simctl: simctl)), [sim, docker], box)

        let report = try #require(events.finished.first)
        #expect(report.freedBytes == 777)
        #expect(report.outcomes.map(\.skip) == [nil, .notPermitted])
        #expect(simctl.runs.withLock { $0 } == 1)
        #expect(box.exists("home/Library/Developer/CoreSimulator/Devices/keep/f"))
    }

    /// Bug: an item held open by a process is cleaned anyway.
    @Test func inUseItemIsSkipped() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Caches/busy/f")
        let item = try box.item(1, "home/Library/Caches/busy")
        let source = StaticProcessPaths(paths: [box.path("home/Library/Caches/busy/f")])

        let events = await run(Cleaner(context: box.context(inUse: InUseChecker(processes: source))), [item], box)

        #expect(events.finished.first?.outcomes.first?.skip == .inUse)
        #expect(box.exists("home/Library/Caches/busy/f"))
    }
}

extension CleanerTests {
    /// Bug: protection decided from a denylist built when the run started. Mail is replaced by a new directory and
    /// the scanned item moved into it afterwards; only a fresh live check sees that it is now inside Mail.
    @Test func protectedDirectoryRecreatedAfterSetupIsHonored() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Mail/V10/m.emlx")
        let item = try box.item(1, "home/Library/Mail/V10")
        let hooks = CleanTestHooks(beforeItem: { _ in
            let fm = FileManager.default
            try? fm.moveItem(atPath: box.path("home/Library/Mail/V10"), toPath: box.path("home/V10-moving"))
            try? fm.removeItem(atPath: box.path("home/Library/Mail"))
            try? fm.createDirectory(atPath: box.path("home/Library/Mail"), withIntermediateDirectories: true)
            try? fm.moveItem(atPath: box.path("home/V10-moving"), toPath: box.path("home/Library/Mail/V10"))
        })
        // The item path is only allowed while Mail does not exist as a protected parent at check time.
        let tree = box.tree()

        let events = await collect(Cleaner(context: box.context(), hooks: hooks)
            .clean([item], tree: tree, overlay: StorageTreeOverlay(tree: tree)))

        #expect(events.finished.first?.outcomes.first?.skip == .denied(.protected))
        #expect(box.list("home/Library/Mail/V10") == ["m.emlx"])
    }

    /// Bug: starting a new run resets the cancellation of a run that is still going (shared flag).
    @Test func cancelOfOneRunDoesNotLeakIntoALaterRun() async throws {
        let box = try CleanSandbox()
        try box.write("home/Library/Caches/a/f")
        try box.write("home/Library/Caches/b/f")
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let hooks = CleanTestHooks(beforeItem: { _ in
            // Only the first item of run A parks here, with the run already in progress.
            let first = calls.withLock { (n: inout Int) -> Bool in
                n += 1
                return n == 1
            }
            guard first else { return }
            entered.signal()
            proceed.wait()
        })
        let cleaner = Cleaner(context: box.context(), hooks: hooks)
        let tree = box.tree()
        let overlay = StorageTreeOverlay(tree: tree)
        let a = cleaner.clean([try box.item(1, "home/Library/Caches/a")], tree: tree, overlay: overlay)
        awaitSignal(entered)
        cleaner.cancel()
        let b = cleaner.clean([try box.item(2, "home/Library/Caches/b")], tree: tree, overlay: overlay)
        proceed.signal()

        let eventsA = await collect(a)
        let eventsB = await collect(b)

        #expect(eventsA.finished.first?.cancelled == true)
        #expect(eventsA.finished.first?.outcomes.first?.skip == .cancelled)
        #expect(box.exists("home/Library/Caches/a/f"))
        #expect(eventsB.finished.first?.cancelled == false)
        #expect(!box.exists("home/Library/Caches/b"))
    }

    /// Bug: after `trashItem` a different file sits under the Trash name and the undo record adopts it, so undo would
    /// move a file we never trashed.
    @Test func replacedTrashEntryGetsNoUndoRecord() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/a.txt")
        let item = try box.item(1, "home/Documents/a.txt", mode: .trash)

        let events = await run(Cleaner(context: box.context(trash: ReplacingTrash(directory: box.fakeTrash))), [item], box)

        let report = try #require(events.finished.first)
        #expect(report.undo == nil)
        #expect(report.trashedBytes == 1000)
        #expect(report.outcomes.first?.trashedTo == box.path("faketrash/a.txt"))
    }

    /// Bug: two links of one file in different removed children credit its bytes twice; a file with a link outside
    /// the removed set credits bytes although nothing was freed.
    @Test func hardLinkedBytesAreCreditedOnceAndOnlyWhenLastLinkWent() async throws {
        let box = try CleanSandbox()
        let first = try box.write("home/Library/Caches/pair/a", bytes: 16384)
        #expect(link(first, box.path("home/Library/Caches/pair/b")) == 0)
        let kept = try box.write("home/Library/Caches/shared/c", bytes: 16384)
        try box.makeDir("home/Documents")
        #expect(link(kept, box.path("home/Documents/outside-link")) == 0)
        let oneCopy = allocated(box, "home/Library/Caches/pair/a")
        #expect(oneCopy >= 16384)
        let items = [
            try box.item(1, "home/Library/Caches/pair", keepParent: true),
            try box.item(2, "home/Library/Caches/shared", keepParent: true),
        ]

        let events = await run(Cleaner(context: box.context()), items, box)

        let report = try #require(events.finished.first)
        #expect(report.freedBytes == oneCopy)
        #expect(events.freed.reduce(0, +) == oneCopy)
        #expect(box.exists("home/Documents/outside-link"))
    }

    /// Bug: a `.freed` event arrives before the `.item` event of the same item (simctl, keep-parent children).
    @Test func freedNeverPrecedesItsItemEvent() async throws {
        let box = try CleanSandbox()
        for n in 0 ..< 8 { try box.write("home/Library/Caches/many/f\(n)", bytes: 8192) }
        let sim = CleanupItem(id: 1, nodeID: nil, path: box.path("home/Library/Developer/CoreSimulator/Devices"),
                              name: "Devices", category: .developer, tier: .review, mode: .simctl, identity: nil,
                              allocBytes: 777)
        let items = [sim, try box.item(2, "home/Library/Caches/many", keepParent: true)]

        let events = await collectOrdered(Cleaner(context: box.context()).clean(items, tree: box.tree(),
                                                                                 overlay: StorageTreeOverlay(tree: box.tree())))

        var detached: UInt64 = 0
        var freed: UInt64 = 0
        var sawFreed = false
        for event in events {
            switch event {
            case let .item(outcome): detached += outcome.detachedBytes
            case let .freed(bytes):
                freed += bytes
                sawFreed = true
                #expect(freed <= detached)
            default: break
            }
        }
        #expect(sawFreed)
        #expect(freed == detached)
    }

    /// Bug: cancelling while the loop waits for a delete slot (or inside the item) leaves `cancelled == false`
    /// and the item without a `.cancelled` outcome.
    @Test func cancelWhileWaitingForSlotIsReported() async throws {
        let box = try CleanSandbox()
        let names = ["a", "b", "c", "d", "e"]
        for name in names { try box.write("home/Library/Caches/\(name)/f") }
        let items = try names.enumerated().map { try box.item(Int32($0.offset), "home/Library/Caches/\($0.element)") }
        let gated = GatedDeleter(inner: DeleteWorker(slim: false))
        let holder = Mutex<Cleaner?>(nil)
        // Items 0-3 hold all four slots (their deletes are blocked on the gate). The hook runs for item 4 after the
        // item-level cancel check and right before the slot wait: the cancel lands exactly there, and the gate
        // opens only afterwards so the wait can end.
        let hooks = CleanTestHooks(beforeSlotWait: { index in
            guard index == Cleaner.maxInFlight else { return }
            holder.withLock { $0 }?.cancel()
            gated.release(Cleaner.maxInFlight)
        })
        let cleaner = Cleaner(context: box.context(deleter: gated), hooks: hooks)
        holder.withLock { $0 = cleaner }

        let events = await run(cleaner, items, box)

        let report = try #require(events.finished.first)
        #expect(report.cancelled)
        #expect(report.freedBytes == 4 * 1000)
        #expect(report.outcomes.map(\.skip) == [nil, nil, nil, nil, .cancelled])
        #expect(box.exists("home/Library/Caches/e/f"))
    }
}

extension CleanerTests {
    private func emptyTrashWithSwap(_ box: CleanSandbox, recreateWithOwnEntry: Bool) async throws -> CleanEvents {
        try box.write("home/.Trash/V10/mail.emlx")
        let hooks = CleanTestHooks(beforeItem: { index in
            guard index == 0 else { return }
            // The listed `.Trash` becomes ~/Library/Mail and a new `.Trash` takes its place.
            try? FileManager.default.createDirectory(atPath: box.path("home/Library"), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(atPath: box.path("home/.Trash"), toPath: box.path("home/Library/Mail"))
            try? FileManager.default.createDirectory(atPath: box.path("home/.Trash"), withIntermediateDirectories: true)
            if recreateWithOwnEntry { _ = try? box.write("home/.Trash/V10/own.txt") }
        })
        return await collect(Cleaner(context: box.context(), hooks: hooks).emptyTrash())
    }

    /// Bug: Empty Trash keeps working through the directory it listed after that directory was renamed to
    /// ~/Library/Mail, and deletes protected mail while reporting success.
    @Test func emptyTrashDoesNotFollowRenamedTrashFolder() async throws {
        let box = try CleanSandbox()

        let events = try await emptyTrashWithSwap(box, recreateWithOwnEntry: false)

        #expect(box.list("home/Library/Mail/V10") == ["mail.emlx"])
        #expect(events.freed.isEmpty)
        #expect(events.finished.first?.freedBytes == 0)
        #expect(events.finished.first?.outcomes.map(\.skip) == [.vanished])
    }

    /// Bug: same swap, but the new `.Trash` has an entry of the same name; it must not be emptied in place of the
    /// one that was listed (the folder is not the one we listed).
    @Test func emptyTrashRefusesReplacedTrashFolderWithSameEntryName() async throws {
        let box = try CleanSandbox()

        let events = try await emptyTrashWithSwap(box, recreateWithOwnEntry: true)

        #expect(box.list("home/Library/Mail/V10") == ["mail.emlx"])
        #expect(box.list("home/.Trash/V10") == ["own.txt"])
        #expect(events.finished.first?.outcomes.map(\.skip) == [.changedSinceScan])
    }

    /// Bug: a protected folder that did not exist when the run started (so no identity was recorded for it) is
    /// created while the loop waits for a delete slot; the item is then moved through it.
    @Test func protectedFolderCreatedWhileWaitingForSlotIsHonored() async throws {
        let box = try CleanSandbox()
        let names = ["a", "b", "c", "d"]
        for name in names { try box.write("home/Library/Caches/\(name)/f") }
        try box.write("home/stash/V10/mail.emlx")
        let stashed = try box.identity("home/stash/V10")
        var items = try names.enumerated().map { try box.item(Int32($0.offset), "home/Library/Caches/\($0.element)") }
        items.append(CleanupItem(id: 9, nodeID: nil, path: box.path("home/Library/Mail/V10"), name: "V10",
                                 category: .userCaches, tier: .safe, mode: .remove, identity: stashed, allocBytes: 1))
        let gated = GatedDeleter(inner: DeleteWorker(slim: false))
        let hooks = CleanTestHooks(beforeSlotWait: { index in
            guard index == 4 else { return }
            try? FileManager.default.createDirectory(atPath: box.path("home/Library/Mail"),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.moveItem(atPath: box.path("home/stash/V10"),
                                              toPath: box.path("home/Library/Mail/V10"))
            gated.release(4)
        })

        let events = await run(Cleaner(context: box.context(deleter: gated), hooks: hooks), items, box)

        #expect(events.finished.first?.outcomes.last?.skip == .denied(.protected))
        #expect(box.list("home/Library/Mail/V10") == ["mail.emlx"])
    }

    /// Bug: keep-parent keeps deleting children through the directory it holds open after the directory itself was
    /// moved (here: into a new ~/Library/Mail) and its path points somewhere else.
    @Test func keepParentStopsWhenItsDirectoryMoves() async throws {
        let box = try CleanSandbox()
        for n in 0 ..< 4 { try box.write("home/Library/Caches/app/f\(n)") }
        let item = try box.item(1, "home/Library/Caches/app", keepParent: true)
        let waits = Mutex(0)
        let hooks = CleanTestHooks(beforeSlotWait: { _ in
            let n = waits.withLock { (count: inout Int) -> Int in
                count += 1
                return count
            }
            guard n == 2 else { return }
            try? FileManager.default.createDirectory(atPath: box.path("home/Library/Mail"),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.moveItem(atPath: box.path("home/Library/Caches/app"),
                                              toPath: box.path("home/Library/Mail/app"))
        })

        let events = await run(Cleaner(context: box.context(), hooks: hooks), [item], box)

        let outcome = try #require(events.finished.first?.outcomes.first)
        #expect(outcome.committedChildren == 1)
        #expect(outcome.skippedChildren == 3)
        #expect(outcome.partial)
        #expect(box.list("home/Library/Mail/app").count == 3)
    }

    /// Advisory: cost of the per-mutation live check (fresh root, no-follow walk, identity + spelling lookups) with a
    /// realistically large ~/Library. The number is reported, the bound only catches an accidental rebuild per call.
    @Test func authorizationCostIsReported() throws {
        let box = try CleanSandbox()
        for n in 0 ..< 100 { try box.makeDir("home/Library/Child\(n)") }
        try box.write("home/Library/Caches/app/file")
        let list = Denylist.build(home: box.home, scanRoot: box.home, dataDirectories: [box.appData])
        let clock = ContinuousClock()

        var denied = 0
        let elapsed = try clock.measure {
            for _ in 0 ..< 1000 {
                let root = try TrustedRoot(path: box.home)
                let live = try LiveTarget.open(root: root, absolutePath: box.path("home/Library/Caches/app/file"))
                if list.check(live: live) != nil { denied += 1 }
            }
        }

        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("1000 authorizations: \(ms) ms")
        #expect(denied == 0)
        #expect(ms < 5000, "1000 authorizations took \(ms) ms")
    }
}

/// `DispatchSemaphore.wait` is unavailable in async contexts; the hook thread signals promptly, so a sync wrapper is fine.
func awaitSignal(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
}

struct StaticProcessPaths: ProcessPathSource {
    var paths: [String]
    func snapshot() -> HeldPaths { HeldPaths(paths: paths) }
}
