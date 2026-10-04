import Darwin
import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct UndoTests {
    /// Trashes `rel` through the cleaner (fake Trash directory `trashDir`) and returns the undo record.
    private func trash(_ box: CleanSandbox, _ rel: String, trashDir: String? = nil) async throws -> UndoRecord {
        let item = try box.item(7, rel, mode: .trash)
        let tree = box.tree()
        let context = box.context(trash: FakeTrash(directory: trashDir ?? box.fakeTrash))
        let events = await collect(Cleaner(context: context).clean([item], tree: tree,
                                                                    overlay: StorageTreeOverlay(tree: tree)))
        return try #require(events.finished.first?.undo)
    }

    private func store(_ box: CleanSandbox) -> UndoStore {
        UndoStore(file: box.path("appdata/storage-undo.json"), permittedRoot: box.home)
    }

    private func restore(_ box: CleanSandbox, _ record: UndoRecord) async -> CleanEvents {
        await collect(store(box).restore(record))
    }

    /// Bug: undo doesn't put the item back, or reports the wrong final path.
    @Test func restoreMovesItemBackToOriginalPath() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/report.pdf")
        let identity = try box.identity("home/Documents/report.pdf")
        let record = try await trash(box, "home/Documents/report.pdf")
        #expect(!box.exists("home/Documents/report.pdf"))

        let events = await restore(box, record)

        #expect(events.restored.map(\.finalPath) == [box.path("home/Documents/report.pdf")])
        #expect(events.restored.map(\.itemID) == [7])
        #expect(try box.identity("home/Documents/report.pdf") == identity)
        #expect(box.list("faketrash").isEmpty)
        #expect(events.finished.count == 1)
    }

    /// Bug: restore overwrites a file that was created at the original path since.
    @Test func collisionsGetRestoredSuffix() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/a.txt", bytes: 10)
        let record = try await trash(box, "home/Documents/a.txt")
        try box.write("home/Documents/a.txt", bytes: 40)

        let events = await restore(box, record)

        #expect(events.restored.map(\.finalPath) == [box.path("home/Documents/a.txt (restored)")])
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path("home/Documents/a.txt"))).count == 40)
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path("home/Documents/a.txt (restored)"))).count == 10)
    }

    /// Bug: a second collision overwrites the first `(restored)` file instead of counting up.
    @Test func secondCollisionCountsUp() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/a.txt", bytes: 10)
        let record = try await trash(box, "home/Documents/a.txt")
        try box.write("home/Documents/a.txt", bytes: 20)
        try box.write("home/Documents/a.txt (restored)", bytes: 30)

        let events = await restore(box, record)

        #expect(events.restored.map(\.finalPath) == [box.path("home/Documents/a.txt (restored 2)")])
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path("home/Documents/a.txt"))).count == 20)
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.path("home/Documents/a.txt (restored)"))).count == 30)
    }

    /// Bug: restoring fails (or lands elsewhere) when the original parent folders were removed meanwhile.
    @Test func missingParentIsRecreated() async throws {
        let box = try CleanSandbox()
        try box.write("home/Projects/old/deep/f.txt")
        let record = try await trash(box, "home/Projects/old/deep/f.txt")
        try FileManager.default.removeItem(atPath: box.path("home/Projects"))

        let events = await restore(box, record)

        #expect(events.restored.map(\.finalPath) == [box.path("home/Projects/old/deep/f.txt")])
        #expect(box.exists("home/Projects/old/deep/f.txt"))
    }

    /// Bug: a different file that now sits under the trashed name gets moved into the user's folders.
    @Test func substitutedTrashEntryIsRefused() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/a.txt")
        let record = try await trash(box, "home/Documents/a.txt")
        try FileManager.default.removeItem(atPath: box.path("faketrash/a.txt"))
        try box.write("faketrash/a.txt", bytes: 99)

        let events = await restore(box, record)

        #expect(events.restored.isEmpty)
        #expect(events.finished.first?.outcomes.first?.skip == .failed("Trash item was replaced"))
        #expect(!box.exists("home/Documents/a.txt"))
        #expect(box.list("faketrash") == ["a.txt"])
    }

    /// Bug: the Trash entry is replaced after the checks but before the rename (checked once up front only).
    @Test func entryReplacedBeforeRenameIsNotMoved() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/a.txt")
        let record = try await trash(box, "home/Documents/a.txt")
        let swap = UndoStore(file: box.path("appdata/storage-undo.json"), permittedRoot: box.home, beforeRename: {
            try? FileManager.default.removeItem(atPath: box.path("faketrash/a.txt"))
            _ = try? box.write("faketrash/a.txt", bytes: 99)
        })

        let events = await collect(swap.restore(record))

        #expect(events.restored.isEmpty)
        #expect(events.finished.first?.outcomes.first?.skip == .failed("Trash item was replaced"))
        #expect(!box.exists("home/Documents/a.txt"))
    }

    /// Bug: the original parent was replaced by a symlink and the restore writes through it.
    @Test func symlinkedDestinationParentIsRefused() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/sub/a.txt")
        let record = try await trash(box, "home/Documents/sub/a.txt")
        try FileManager.default.removeItem(atPath: box.path("home/Documents/sub"))
        try box.makeDir("outside")
        #expect(symlink(box.path("outside"), box.path("home/Documents/sub")) == 0)

        let events = await restore(box, record)

        #expect(events.restored.isEmpty)
        #expect(events.finished.first?.outcomes.first?.skip != nil)
        #expect(box.list("outside").isEmpty)
        #expect(box.list("faketrash") == ["a.txt"])
    }

    /// Bug: undo only works for ~/.Trash; an item on another volume's `.Trashes/<uid>` can't be restored.
    @Test func nonHomeTrashParentIsRestored() async throws {
        let box = try CleanSandbox()
        let volumeTrash = box.path("volume/.Trashes/501")
        try box.makeDir("volume/.Trashes/501")
        try box.write("home/Documents/a.txt")
        let record = try await trash(box, "home/Documents/a.txt", trashDir: volumeTrash)
        #expect(record.entries.first?.trashParentPath == volumeTrash)

        let events = await restore(box, record)

        #expect(events.restored.map(\.finalPath) == [box.path("home/Documents/a.txt")])
        #expect(box.list("volume/.Trashes/501").isEmpty)
    }

    /// Bug: a Trash folder that is no longer the recorded directory (replaced) is trusted by name.
    @Test func replacedTrashFolderIsRefused() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/a.txt")
        let record = try await trash(box, "home/Documents/a.txt", trashDir: box.path("faketrash"))
        try FileManager.default.moveItem(atPath: box.path("faketrash"), toPath: box.path("faketrash-moved"))
        try box.makeDir("faketrash")
        try box.write("faketrash/a.txt")

        let events = await restore(box, record)

        #expect(events.restored.isEmpty)
        #expect(events.finished.first?.outcomes.first?.skip == .failed("Trash folder changed"))
        #expect(!box.exists("home/Documents/a.txt"))
    }

    /// Bug: prune keeps stale records forever, or drops fresh ones.
    @Test func pruneDropsOldRecordsAndMissingTrashItems() async throws {
        let box = try CleanSandbox()
        try box.write("home/Documents/fresh.txt")
        try box.write("home/Documents/gone.txt")
        var fresh = try await trash(box, "home/Documents/fresh.txt")
        var gone = try await trash(box, "home/Documents/gone.txt")
        try FileManager.default.removeItem(atPath: box.path("faketrash/gone.txt"))
        let now = Date(timeIntervalSince1970: 10_000_000)
        fresh.date = now.addingTimeInterval(-3600)
        gone.date = now.addingTimeInterval(-3600)
        var old = fresh
        old.id = UUID()
        old.date = now.addingTimeInterval(-8 * 86400)
        let s = store(box)
        for record in [fresh, gone, old] { try s.append(record) }

        try s.prune(now: now)

        #expect(try s.records().map(\.id) == [fresh.id])
    }
}
