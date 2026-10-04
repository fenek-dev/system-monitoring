import Darwin
import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct StagingTests {
    private func staging(_ box: CleanSandbox) -> Staging {
        Staging(dir: box.staging, deleter: DeleteWorker(slim: false))
    }

    /// Detaches `rel` (expecting `expected`) from its parent directory.
    private func detach(_ box: CleanSandbox, _ journal: StagingJournal, _ rel: String,
                        expected: FileIdentity) throws -> DetachResult {
        let root = try TrustedRoot(path: box.base)
        let live = try LiveTarget.open(root: root, absolutePath: box.path(rel))
        return journal.detach(parent: live.parent.rawValue, parentPath: (box.path(rel) as NSString).deletingLastPathComponent,
                              parentIdentity: live.parentIdentity, leaf: live.leaf, expected: expected)
    }

    /// Bug: the item at the path was replaced after the scan and the cleaner deletes the new, different file.
    @Test func replacedAfterScanIsRolledBack() throws {
        let box = try CleanSandbox()
        try box.makeDir("home/cache")
        let scanned = try box.identity("home/cache")
        try FileManager.default.removeItem(atPath: box.path("home/cache"))
        try box.write("home/cache/precious.txt")
        let journal = try staging(box).openJournal()

        let result = try detach(box, journal, "home/cache", expected: scanned)

        #expect(result == .skipped(.changedSinceScan, leftover: false))
        #expect(box.list("home/cache") == ["precious.txt"])
        #expect(box.list("staging/pending").isEmpty)
        #expect(box.list("staging/commit").isEmpty)
    }

    /// Bug: a crash between the pending rename and the commit leaves user data hidden in staging forever.
    @Test func sweepRestoresItemLeftInPending() throws {
        let box = try CleanSandbox()
        try box.write("home/cache/f.txt")
        let original = try box.identity("home/cache")
        let hooks = CleanTestHooks(afterPendingRename: { true })
        let journal = try staging(box).openJournal(hooks: hooks)

        let result = try detach(box, journal, "home/cache", expected: original)
        #expect(result == .skipped(.failed("simulated crash"), leftover: true))
        #expect(!box.exists("home/cache"))

        let report = staging(box).sweep()

        #expect(report.restored == 1)
        #expect(report.leftovers == 0)
        #expect(try box.identity("home/cache") == original)
        #expect(box.list("home/cache") == ["f.txt"])
        #expect(box.list("staging/pending").isEmpty)
    }

    /// Bug: when the original name was re-created before the rollback, the rollback overwrites it or the leftover
    /// is deleted.
    @Test func rollbackCollisionLeavesItemInPending() throws {
        let box = try CleanSandbox()
        try box.write("home/cache/f.txt")
        let wrong = FileIdentity(dev: 1, ino: 1, isDirectory: true)
        let hooks = CleanTestHooks(afterPendingRename: {
            // Somebody re-creates the original name between the move and the rollback.
            _ = try? box.write("home/cache")
            return false
        })
        let journal = try staging(box).openJournal(hooks: hooks)

        let result = try detach(box, journal, "home/cache", expected: wrong)

        #expect(result == .skipped(.rollbackCollision, leftover: true))
        // The new file at the original name is untouched, the moved directory waits in pending with its sidecar.
        #expect(box.exists("home/cache"))
        #expect(try box.identity("home/cache").isDirectory == false)
        let pending = box.list("staging/pending")
        #expect(pending.count == 2)
        #expect(pending.filter { $0.hasSuffix(".json") }.count == 1)

        let report = staging(box).sweep()
        #expect(report.restored == 0)
        #expect(report.leftovers == 1)
        #expect(box.list("staging/pending") == pending)
        #expect(box.list("staging/commit").isEmpty)
    }

    /// Bug: staging on another volume makes the rename fail halfway or falls back to a path-based delete.
    @Test func stagingOnAnotherDeviceSkipsWithoutTouchingItem() throws {
        let box = try CleanSandbox()
        try box.write("home/cache/f.txt")
        let original = try box.identity("home/cache")
        let probe = try staging(box).openJournal()
        let hooks = CleanTestHooks(stagingDeviceOverride: probe.stagingDev &+ 1)
        let journal = try staging(box).openJournal(hooks: hooks)

        let result = try detach(box, journal, "home/cache", expected: original)

        #expect(result == .skipped(.stagingOtherVolume, leftover: false))
        #expect(try box.identity("home/cache") == original)
        #expect(box.list("staging/pending").isEmpty)
    }

    /// Bug: the launch sweep deletes pending items (user data) or leaves committed garbage / orphan sidecars.
    @Test func sweepDeletesCommitAndOrphansButNeverPending() throws {
        let box = try CleanSandbox()
        let s = staging(box)
        _ = try s.openJournal()
        try box.write("staging/commit/dead/f.txt")
        try box.write("staging/pending/stray-no-sidecar/f.txt")
        try box.write("staging/pending/gone-item.json", bytes: 2)

        let report = s.sweep()

        #expect(report.deleted == 1)
        #expect(report.orphanSidecars == 1)
        #expect(report.leftovers == 1)
        #expect(box.list("staging/commit").isEmpty)
        #expect(box.list("staging/pending") == ["stray-no-sidecar"])
        #expect(box.list("staging/pending/stray-no-sidecar") == ["f.txt"])
    }
}
