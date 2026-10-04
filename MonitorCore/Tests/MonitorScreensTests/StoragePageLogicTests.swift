import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
import MonitorUIKit
@testable import MonitorScreens
import Testing

@MainActor private final class ScanRuns { var count = 0 }

@Suite("Storage page logic (StoragePageLogicTests)") @MainActor
struct StoragePageLogicTests {
    private let size = CGSize(width: 560, height: 360)

    /// Bug: a scan can be started during a clean, or Cancel is missing while scanning.
    @Test(arguments: [
        (StorageModel.Phase.idle, nil as StorageModel.BusyReason?, false, StorageScanButton(kind: .scan, enabled: true, help: nil)),
        (.ready, nil, true, StorageScanButton(kind: .rescan, enabled: true, help: nil)),
        (.scanning(hasPrevious: false), .scanning, false, StorageScanButton(kind: .cancel, enabled: true, help: nil)),
        (.scanning(hasPrevious: true), .scanning, true, StorageScanButton(kind: .cancel, enabled: true, help: nil)),
        (.ready, .cleaning, true, StorageScanButton(kind: .rescan, enabled: false, help: "Cleaning in progress")),
        (.idle, .cleaning, false, StorageScanButton(kind: .scan, enabled: false, help: "Cleaning in progress")),
    ])
    func scanButton(phase: StorageModel.Phase, busy: StorageModel.BusyReason?, hasResult: Bool,
                    expected: StorageScanButton) {
        #expect(StorageScanButton.make(phase: phase, busy: busy, hasResult: hasResult) == expected)
    }

    private func row(_ node: StorageNodeID?, kind: TTSpaceMapTile.Kind = .normal) -> SpaceMapRow {
        SpaceMapRow(id: node ?? TTSpaceMapLayout.smallerID, kind: kind, name: "x", bytes: 1, sizeText: "", shareText: "",
                    itemsText: "", node: node, estimated: false)
    }

    /// Bug: Move to Trash enabled on a protected path, or disabled without the reason as tooltip.
    @Test func trashStateFollowsPolicy() throws {
        let state = MockStorageState.make(.map)
        let tree = try #require(state.tree)
        let home = MockStorageState.home
        let library = try #require(tree.lookup(path: "\(home)/Library"))
        let mail = try #require(tree.lookup(path: "\(home)/Library/Mail"))
        let pictures = try #require(tree.lookup(path: "\(home)/Pictures"))
        func trash(_ r: SpaceMapRow, canClean: Bool = true) -> SpaceMapLogic.TrashState {
            SpaceMapLogic.trashState(row: r, policy: state.policy, tree: tree, canClean: canClean)
        }
        #expect(trash(row(library)) == .disabled(reason: "Protected system or home folder"))
        #expect(trash(row(mail)) == .disabled(reason: "Protected data (Mail, Keychains, iCloud…)"))
        #expect(trash(row(pictures)) == .allowed)
        #expect(trash(row(pictures), canClean: false) == .disabled(reason: "Wait for the scan to finish"))
        #expect(trash(row(nil, kind: .smaller)) == .disabled(reason: "Can't verify this item"))
        #expect(trash(row(pictures, kind: .restricted)) == .disabled(reason: "Can't verify this item"))
        let stale = StoragePolicy(treeVersion: tree.version &+ 1, anchors: [], protected: [])
        #expect(SpaceMapLogic.trashState(row: row(pictures), policy: stale, tree: tree, canClean: true)
            == .disabled(reason: "Can't verify this item"))
        #expect(SpaceMapLogic.reason(.outsideRoot) == "Outside the scanned folder")
    }

    private func child(_ id: Int32, _ name: String, _ bytes: UInt64?) -> SpaceMapChild {
        SpaceMapChild(id: .node(id), tileID: id, name: name, bytes: bytes, isDirectory: true)
    }

    /// Bug: the table and the map disagree on the set of entries, or a hover id has no counterpart.
    @Test func tableRowsAreTheLayoutSet() {
        var children = [child(1, "Big", 50_000_000_000), child(2, "Mid", 10_000_000_000)]
        children += (3...12).map { child(Int32($0), "tiny\($0)", 1_000_000) }
        let derived = SpaceMapLogic.derive(children: children, tree: nil, provenance: .exact, size: size)
        let layout = TTSpaceMapLayout.make(derived.tiles, in: size)
        #expect(layout.smallerCount == 10)
        #expect(derived.rows.map(\.id) == layout.placed.map(\.tile.id))
        #expect(derived.rows.map(\.id) == derived.order)
        #expect(derived.rows.filter { $0.kind == .smaller }.map(\.name) == ["10 smaller items"])
        #expect(derived.rows.last?.id == TTSpaceMapLayout.smallerID)
        #expect(derived.rows.last?.drillable == false)
        #expect(derived.rows.last?.bytes == 10_000_000)
    }

    /// Bug: restricted layout weights leaked into byte totals ("1 GB + 201 restricted" showed 4.02 GB / 402 %).
    @Test func restrictedWeightsNeverBecomeBytes() throws {
        var children = [child(1, "Known", 1_000_000_000)]
        children += (2...202).map { child(Int32($0), "locked\($0)", nil) }
        let derived = SpaceMapLogic.derive(children: children, tree: nil, provenance: .exact, size: size)
        let smaller = try #require(derived.rows.last)
        #expect(smaller.kind == .smaller)
        #expect(smaller.name == "201 restricted")
        #expect(smaller.sizeText == "—")
        #expect(smaller.shareText == "—")
        #expect(derived.tail == SpaceMapTail(knownBytes: 0, knownCount: 0, restrictedCount: 201))
        let known = try #require(derived.rows.first { $0.id == 1 })
        #expect(known.shareText == "100%")
    }

    /// Bug: the tail row hides that restricted folders are part of it, or counts their weight as bytes.
    @Test func smallerRowSumsOnlyKnownBytes() {
        var children = [child(1, "Big", 100_000_000_000)]
        children += (2...31).map { child(Int32($0), "locked\($0)", nil) }
        children += (32...41).map { child(Int32($0), "tiny\($0)", 1_000_000) }
        let derived = SpaceMapLogic.derive(children: children, tree: nil, provenance: .exact, size: size)
        #expect(derived.tail == SpaceMapTail(knownBytes: 10_000_000, knownCount: 10, restrictedCount: 30))
        #expect(derived.rows.last?.name == "10 smaller items and 30 restricted")
        #expect(derived.rows.last?.sizeText == "10 MB")
    }

    /// Advisory scale check: 10k children keep the table bounded by the layout cut.
    @Test func tenThousandChildrenStayBounded() {
        let children = (0..<10_000).map { child(Int32($0), "n\($0)", UInt64(10_000 - $0) * 1_000_000) }
        let derived = SpaceMapLogic.derive(children: children, tree: nil, provenance: .exact, size: size)
        #expect(derived.rows.count <= TTSpaceMapLayout.maxTiles + 1)
        #expect(derived.tiles.count == 10_000)
        #expect(derived.tiles.filter { !$0.valueText.isEmpty }.count == derived.rows.count - 1)
    }

    /// Bug: a restricted folder shows a size, or its nominal tile weight sorts it out of place in the layout input.
    @Test func restrictedTileHasNoSizeAndIsNotDrillable() {
        let children = [child(1, "Big", 3_000_000_000), child(2, "Locked", nil), child(3, "Mid", 2_000_000_000),
                        child(4, "Small", 1_000)]
        let derived = SpaceMapLogic.derive(children: children, tree: nil, provenance: .exact, size: size)
        #expect(derived.tiles.map(\.value) == derived.tiles.map(\.value).sorted(by: >))
        let locked = derived.rows.first { $0.id == 2 }
        #expect(locked?.kind == .restricted)
        #expect(locked?.sizeText == "—")
        #expect(locked?.drillable == false)
    }

    /// Bug: tile tooltips divided by the layout total, so restricted tiles' nominal weight shrank every share (up to 10 %).
    @Test func tileShareUsesKnownBytesOnly() throws {
        let children = [child(1, "Big", 3_000_000_000), child(2, "Locked", nil), child(3, "Mid", 1_000_000_000)]
        let derived = SpaceMapLogic.derive(children: children, tree: nil, provenance: .exact, size: size)
        let big = try #require(derived.tiles.first { $0.id == 1 })
        #expect(big.share == 0.75)
        #expect(derived.tiles.first { $0.id == 2 }?.share == nil)
    }

    /// Bug: arrow navigation runs off the ends; Return drills a merged or restricted tile.
    @Test func keyboardClampsAndOnlyDrillsNormalTiles() {
        let order: [Int32] = [5, 7, 9, TTSpaceMapLayout.smallerID]
        #expect(SpaceMapLogic.step(.next, from: nil, in: order) == 5)
        #expect(SpaceMapLogic.step(.previous, from: 5, in: order) == 5)
        #expect(SpaceMapLogic.step(.next, from: 7, in: order) == 9)
        #expect(SpaceMapLogic.step(.next, from: TTSpaceMapLayout.smallerID, in: order) == TTSpaceMapLayout.smallerID)
        #expect(SpaceMapLogic.step(.next, from: 99, in: order) == 5)
        #expect(SpaceMapLogic.step(.next, from: 1, in: []) == nil)
        let rows = [row(5), row(6, kind: .restricted), row(nil, kind: .smaller)]
        #expect(SpaceMapLogic.drillTarget(5, rows: rows) == 5)
        #expect(SpaceMapLogic.drillTarget(6, rows: rows) == nil)
        #expect(SpaceMapLogic.drillTarget(TTSpaceMapLayout.smallerID, rows: rows) == nil)
        #expect(SpaceMapLogic.drillTarget(nil, rows: rows) == nil)
    }

    /// Bug: the table moved the selection but Return acted on a hover left behind by the pointer.
    @Test func tableSelectionDragsHoverAlong() {
        let rows = [row(5), row(7)]
        var focus = SpaceMapFocus(hover: 5, selection: nil)
        focus.selection = 7 // the table's own arrow key
        focus.selectionChanged()
        #expect(focus.hover == 7)
        #expect(SpaceMapLogic.drillTarget(focus.current, rows: rows) == 7)
        // Map arrows continue from the same place and keep both in step.
        let moved = focus.move(.previous, order: [5, 7])
        #expect(moved)
        #expect(focus == SpaceMapFocus(hover: 5, selection: 5))
        var empty = SpaceMapFocus(hover: nil, selection: nil)
        empty.selectionChanged()
        #expect(empty.hover == nil)
    }

    /// Bug: a cancelled first scan left its partial tree, so the retry showed "Scanned …" and a previous result.
    @Test func cancelledFirstScanRetriesAsFirstScan() async throws {
        let partial = try #require(MockStorageState.make(.scanning).tree)
        let runs = ScanRuns()
        var actions = StorageActions()
        actions.scan = { _, _ in
            runs.count += 1
            if runs.count > 1 { return AsyncStream { _ in } }
            return AsyncStream { c in
                c.yield(.partial(partial))
                c.yield(.failed(.cancelled))
                c.finish()
            }
        }
        let model = StorageModel(actions: actions, home: MockStorageState.home)
        model.startScan()
        for _ in 0..<1000 where model.phase != .failed(.cancelled) { await Task.yield() }
        #expect(model.phase == .failed(.cancelled))
        // The first scan's consumer finishes a few turns after its terminal event; startScan is a no-op until then.
        for _ in 0..<1000 where model.phase == .failed(.cancelled) {
            model.startScan()
            await Task.yield()
        }
        #expect(model.phase == .scanning(hasPrevious: true)) // the model counts the partial tree
        let finished = model.spaceMap.overlay != nil
        #expect(!finished)
        #expect(StorageContentState.make(phase: model.phase, hasFinalTree: finished) == .scanning(hasPrevious: false))
        #expect(StorageChrome.lastScan(finishedTreeDate: finished ? model.spaceMap.tree?.scanDate : nil,
                                       summary: nil, root: model.root) == nil)
        #expect(StorageContentState.make(phase: .ready, hasFinalTree: false) == .neverScanned)
        #expect(StorageContentState.make(phase: .failed(.cancelled), hasFinalTree: false) == .neverScanned)
        let saved = StorageSummary(root: model.root, scanDate: Date(timeIntervalSince1970: 5), reclaimableBytes: nil,
                                   provenance: .exact, trashBytes: nil)
        #expect(StorageChrome.lastScan(finishedTreeDate: nil, summary: saved, root: model.root)
            == Date(timeIntervalSince1970: 5))
    }
}
