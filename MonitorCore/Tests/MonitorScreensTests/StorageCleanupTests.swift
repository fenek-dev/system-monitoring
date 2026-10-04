import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("Storage cleanup flow (StorageCleanupTests)") @MainActor
struct StorageCleanupTests {
    private func model(log: ActionLog) -> StorageModel {
        let state = MockStorageState.make(.cleanup)
        let model = StorageModel(actions: MockDataProvider(scenario: .calm).storageActions(log: log, state: state),
                                 home: MockStorageState.home, now: { MockDataProvider.referenceDate })
        if let tree = state.tree, let overlay = state.overlay, let set = state.cleanup {
            model.adopt(tree: tree, overlay: overlay, cleanup: set)
        }
        return model
    }

    private let yes: ConfirmAsk = { _, _, _ in true }
    private let no: ConfirmAsk = { _, _, _ in false }

    /// Bug: items deleted although the user cancelled the dialog.
    @Test func cancelledConfirmDeletesNothing() async {
        let log = ActionLog()
        let storage = model(log: log)
        #expect(storage.cleanup.selectedCount > 0)
        let result = await CleanFlow.run(storage: storage, confirm: no)
        #expect(result.outcome == .declined)
        #expect(log.storageItemIDs == [])
    }

    /// Bug: clean proceeds outside a dashboard window, where no dialog can be shown.
    @Test func missingDialogDeletesNothing() async {
        let log = ActionLog()
        let storage = model(log: log)
        let result = await CleanFlow.run(storage: storage, confirm: CleanFlow.ask(nil))
        #expect(result.outcome == .declined)
        #expect(log.storageItemIDs == [])
    }

    /// Bug: an item a process holds open is deleted because it was ticked before the app started.
    @Test func confirmedCleanSkipsNewlyInUse() async {
        let log = ActionLog()
        let storage = model(log: log)
        // Safe and not flagged as running, so ticked by default; the mock's in-use check reports it.
        #expect(storage.cleanup.checked.contains(4))
        let expected = storage.cleanup.checked.subtracting([4])
        let result = await CleanFlow.run(storage: storage, confirm: yes)
        #expect(result.outcome == .started)
        #expect(result.newlyInUse == 1)
        #expect(Set(log.storageItemIDs) == expected)
        #expect(!log.storageItemIDs.contains(4))
        #expect(storage.cleanup.inUse == [4])
    }

    /// Bug: Empty Trash runs without asking.
    @Test func emptyTrashAsksFirst() async {
        let log = ActionLog()
        let storage = model(log: log)
        #expect(await CleanToastActions.emptyTrash(storage: storage, confirm: no) == false)
        #expect(log.records.filter { $0.kind == .emptyTrash }.isEmpty)
        #expect(await CleanToastActions.emptyTrash(storage: storage, confirm: yes))
        #expect(log.records.filter { $0.kind == .emptyTrash }.count == 1)
    }

    private func item(_ id: Int32, _ name: String, _ mode: DeleteMode, bytes: UInt64 = 1_000_000_000,
                      _ provenance: SizeProvenance = .exact) -> CleanupItem {
        CleanupItem(id: id, nodeID: nil, path: "/\(name)", name: name, category: .userCaches, tier: .safe, mode: mode,
                    identity: nil, allocBytes: bytes, privateBytesExcludingLinks: bytes, sizeProvenance: provenance)
    }

    private func part(_ kind: CleanConfirmText.Kind, _ bytes: UInt64?,
                      _ provenance: SizeProvenance = .exact) -> CleanConfirmText.Part {
        CleanConfirmText.Part(kind: kind, bytes: bytes, provenance: provenance)
    }

    /// Bug: the dialog's breakdown summed row sizes, ignoring hard-link credit, so it disagreed with the headline.
    @Test func breakdownMatchesHeadlineForHardLinks() async {
        let storage = model(log: ActionLog())
        let cleanup = storage.cleanup
        for id in cleanup.checked where id != 15 && id != 16 { cleanup.toggle(.item(id)) }
        #expect(cleanup.checked == [15, 16])
        var title = ""
        var message = ""
        _ = await CleanFlow.run(storage: storage, confirm: { t, m, _ in
            title = t
            message = m
            return false
        })
        let headline = StorageFormat.bytes(cleanup.selectedBytes, provenance: cleanup.selectedProvenance)
        #expect(title == "Clean \(headline)?")
        #expect(message.hasPrefix("Delete permanently: \(headline) "))
    }

    /// Bug: unticking an unprocessed item during a clean changed the UI but not the confirmed batch.
    @Test func selectionIsFrozenWhileCleaning() {
        let storage = model(log: ActionLog())
        let cleanup = storage.cleanup
        let items = cleanup.items.filter { cleanup.checked.contains($0.id) }
        let before = cleanup.checked
        #expect(storage.clean(items))
        cleanup.toggle(.item(items[0].id))
        #expect(cleanup.checked == before)
        for line in cleanup.lines() where line.item == nil {
            cleanup.toggle(line.id)
            #expect(cleanup.checked == before)
        }
        let line = cleanup.lines()[0]
        #expect(CleanupRow(line: line, check: .on, inUse: false, expanded: false, locked: true).disabledReason == "Cleaning…")
        #expect(CleanupRow(line: line, check: .on, inUse: false, expanded: false, locked: false).disabledReason == nil)
    }

    /// Bugs: unbounded in-use list, "+0 more", missing "≈" on estimates, wrong line order or labels.
    @Test func messageText() {
        let busy = (1...7).map { item(Int32($0), "app\($0)", .remove) }
        let seven = CleanConfirmText.make(parts: [], total: 0, provenance: .exact, inUse: busy)
        #expect(seven.message == "\nIn use, skipped:\napp1\napp2\napp3\napp4\napp5\n+2 more")
        let five = CleanConfirmText.make(parts: [], total: 0, provenance: .exact, inUse: Array(busy.prefix(5)))
        #expect(!five.message.contains("more"))

        let mixed = CleanConfirmText.make(
            parts: [part(.permanent, 3_000_000_000), part(.trash, 500_000_000), part(.downloads, 3_000_000_000)],
            total: 6_500_000_000, provenance: .exact, inUse: [])
        #expect(mixed.title == "Clean 6.5 GB?")
        #expect(mixed.message == """
            Delete permanently: 3.0 GB (caches, build data)
            Move to Trash: 500 MB (leftovers, large files)
            Remove downloads: 3.0 GB (iCloud)
            """)

        let estimate = CleanConfirmText.make(parts: [part(.trash, 1_000_000_000, .estimate)], total: 1_000_000_000,
                                             provenance: .estimate, inUse: [])
        #expect(estimate.title == "Clean ≈1.0 GB?")
        #expect(estimate.message == "Move to Trash: ≈1.0 GB (leftovers, large files)")
    }

    /// Bug: trashed bytes reported as freed.
    @Test(arguments: [
        (UInt64(0), UInt64(0), UInt64(0), false, "Nothing was cleaned"),
        (1_200_000_000, 0, 0, false, "Freed 1.2 GB"),
        (0, 300_000_000, 0, false, "Moved 300 MB to Trash"),
        (1_000_000_000, 300_000_000, 200_000_000, false, "Freed 1.2 GB · Moved 300 MB to Trash"),
        (0, 300_000_000, 0, true, "Stopped. Moved 300 MB to Trash"),
        (0, 0, 0, true, "Stopped. Nothing was cleaned"),
    ])
    func toastText(freed: UInt64, trashed: UInt64, evicted: UInt64, cancelled: Bool, expected: String) {
        let report = CleanReport(freedBytes: freed, trashedBytes: trashed, evictedBytes: evicted, cancelled: cancelled)
        #expect(CleanToastText.make(report) == expected)
        if freed + evicted == 0 { #expect(!CleanToastText.make(report).contains("Freed")) }
    }
}
