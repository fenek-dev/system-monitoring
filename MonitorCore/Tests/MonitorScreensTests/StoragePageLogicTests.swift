import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
import MonitorUIKit
@testable import MonitorScreens
import Testing

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
                    itemsText: "", node: node)
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
        let tiles = SpaceMapLogic.tiles(children, provenance: .exact)
        let layout = TTSpaceMapLayout.make(tiles, in: size)
        let rows = SpaceMapLogic.rows(layout: layout, children: children, tree: nil, provenance: .exact)
        #expect(layout.smallerCount == 10)
        #expect(rows.map(\.id) == layout.placed.map(\.tile.id))
        #expect(rows.filter { $0.kind == .smaller }.map(\.name) == ["10 smaller items"])
        #expect(rows.last?.id == TTSpaceMapLayout.smallerID)
        #expect(rows.last?.drillable == false)
    }

    /// Bug: a restricted folder shows a size, or its nominal tile weight sorts it out of place in the layout input.
    @Test func restrictedTileHasNoSizeAndIsNotDrillable() {
        let children = [child(1, "Big", 3_000_000_000), child(2, "Locked", nil), child(3, "Mid", 2_000_000_000),
                        child(4, "Small", 1_000)]
        let tiles = SpaceMapLogic.tiles(children, provenance: .exact)
        #expect(tiles.map(\.value) == tiles.map(\.value).sorted(by: >))
        let layout = TTSpaceMapLayout.make(tiles, in: size)
        let rows = SpaceMapLogic.rows(layout: layout, children: children, tree: nil, provenance: .exact)
        let locked = rows.first { $0.id == 2 }
        #expect(locked?.kind == .restricted)
        #expect(locked?.sizeText == "—")
        #expect(locked?.drillable == false)
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
}
