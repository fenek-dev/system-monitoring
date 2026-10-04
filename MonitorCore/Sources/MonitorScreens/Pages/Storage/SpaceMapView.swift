import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import os
import SwiftUI

// MARK: - Pure logic

struct SpaceMapRow: Identifiable, Equatable {
    /// The tile id, so the map's hover id and the table's hover id are the same value.
    let id: Int32
    let kind: TTSpaceMapTile.Kind
    let name: String
    let bytes: UInt64?
    let sizeText: String
    let shareText: String
    let itemsText: String
    /// nil for the merged "smaller items" row and for undone entries that have no tree node.
    let node: StorageNodeID?
    /// Size is an allocated-bytes estimate (clones may free more).
    let estimated: Bool

    var drillable: Bool { kind == .normal && node != nil }
}

/// What the merged "N smaller items" tile stands for: only sizes that are actually known.
struct SpaceMapTail: Equatable {
    var knownBytes: UInt64 = 0
    var knownCount = 0
    var restrictedCount = 0
}

/// Everything the view derives from (children, size): computed once per input version, not per body.
struct SpaceMapDerived {
    var tiles: [TTSpaceMapTile] = []
    var rows: [SpaceMapRow] = []
    var order: [Int32] = []
    var tail = SpaceMapTail()
}

enum SpaceMapLogic {
    /// Layout weight of a restricted tile relative to the known bytes of its siblings. A weight, never a size: it
    /// is kept out of every byte total and percentage.
    static let restrictedShare = 0.02
    /// Cap on the weight all restricted tiles together may add, so many of them cannot dwarf the known tiles.
    static let restrictedBudget = 0.10

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// Presorted tiles (the layout requires it), the table rows of exactly the layout's set, the keyboard order
    /// and the tail's known totals. Only tiles the layout keeps get a formatted size: with 10k children the
    /// cut leaves a few hundred.
    static func derive(children: [SpaceMapChild], tree: StorageTree?, provenance: SizeProvenance,
                       size: CGSize) -> SpaceMapDerived {
        let known = children.reduce(0.0) { $0 + Double($1.bytes ?? 0) }
        let restricted = children.reduce(0) { $0 + ($1.bytes == nil ? 1 : 0) }
        let perTile: Double = min(restrictedShare, restrictedBudget / Double(max(restricted, 1)))
        let nominal: Double = known > 0 ? max(known * perTile, 1) : 1
        var weighted: [(index: Int, child: SpaceMapChild, weight: Double)] = []
        for (i, child) in children.enumerated() {
            weighted.append((i, child, child.bytes.map { Double($0) } ?? nominal))
        }
        weighted.sort { $0.weight != $1.weight ? $0.weight > $1.weight : $0.index < $1.index }
        let bare: [TTSpaceMapTile] = weighted.map { entry in
            let isRestricted = entry.child.bytes == nil
            return TTSpaceMapTile(id: entry.child.tileID, value: entry.weight, label: entry.child.name,
                                  valueText: isRestricted ? TTFormat.unavailable : "",
                                  kind: isRestricted ? .restricted : .normal)
        }
        let layout = TTSpaceMapLayout.make(bare, in: size)
        let shownIDs = Set(layout.shown.map(\.id))

        let byTile = Dictionary(children.map { ($0.tileID, $0) }, uniquingKeysWith: { first, _ in first })
        let tiles = bare.map { tile -> TTSpaceMapTile in
            guard shownIDs.contains(tile.id), tile.kind == .normal, let bytes = byTile[tile.id]?.bytes else { return tile }
            var t = tile
            t.valueText = StorageFormat.bytes(bytes, provenance: provenance, style: .headline)
            return t
        }

        var tail = SpaceMapTail()
        for child in children where !shownIDs.contains(child.tileID) {
            if let bytes = child.bytes {
                tail.knownBytes += bytes
                tail.knownCount += 1
            } else {
                tail.restrictedCount += 1
            }
        }

        func share(_ bytes: UInt64) -> String { known > 0 ? TTFormat.percent(Double(bytes) / known) : TTFormat.unavailable }
        let estimated = provenance != .exact
        var rows: [SpaceMapRow] = []
        for tile in layout.shown {
            guard let child = byTile[tile.id] else { continue }
            var node: StorageNodeID?
            if case let .node(n) = child.id { node = n }
            let items: String = if let tree, let node, child.isDirectory, child.bytes != nil { TTFormat.count(Int(tree.childCount[Int(node)])) }
                else { TTFormat.unavailable }
            rows.append(SpaceMapRow(
                id: tile.id, kind: tile.kind, name: child.name, bytes: child.bytes,
                sizeText: StorageFormat.bytes(child.bytes, provenance: provenance, style: .detail),
                shareText: child.bytes.map(share) ?? TTFormat.unavailable, itemsText: items, node: node,
                estimated: estimated && child.bytes != nil))
        }
        if layout.smallerCount > 0 {
            let name = switch (tail.knownCount, tail.restrictedCount) {
            case let (k, 0): plural(k, "smaller item", "smaller items")
            case let (0, r): "\(r) restricted"
            case let (k, r): plural(k, "smaller item", "smaller items") + " and \(r) restricted"
            }
            rows.append(SpaceMapRow(
                id: TTSpaceMapLayout.smallerID, kind: .smaller, name: name,
                bytes: tail.knownCount > 0 ? tail.knownBytes : nil,
                sizeText: tail.knownCount > 0
                    ? StorageFormat.bytes(tail.knownBytes, provenance: provenance, style: .detail) : TTFormat.unavailable,
                shareText: tail.knownCount > 0 ? share(tail.knownBytes) : TTFormat.unavailable,
                itemsText: TTFormat.unavailable, node: nil, estimated: estimated && tail.knownCount > 0))
        }
        return SpaceMapDerived(tiles: tiles, rows: rows, order: layout.placed.map(\.tile.id), tail: tail)
    }

    enum Step { case previous, next }

    /// Arrow keys walk the size-sorted order and stop at the ends. No current tile: the first.
    static func step(_ step: Step, from current: Int32?, in order: [Int32]) -> Int32? {
        guard !order.isEmpty else { return nil }
        guard let current, let i = order.firstIndex(of: current) else { return order[0] }
        switch step {
        case .previous: return order[max(0, i - 1)]
        case .next: return order[min(order.count - 1, i + 1)]
        }
    }

    /// Return drills only a normal tile that has a tree node.
    static func drillTarget(_ id: Int32?, rows: [SpaceMapRow]) -> StorageNodeID? {
        guard let id, let row = rows.first(where: { $0.id == id }), row.drillable else { return nil }
        return row.node
    }

    enum TrashState: Equatable {
        case allowed
        case disabled(reason: String)
    }

    /// "Move to Trash…" availability; the reason is the tooltip of the disabled item.
    static func trashState(row: SpaceMapRow, policy: StoragePolicy, tree: StorageTree?, canClean: Bool) -> TrashState {
        guard let tree, let node = row.node, row.kind == .normal else {
            return .disabled(reason: reason(.unverifiable))
        }
        if let deny = policy.denyReason(trash: node, in: tree) { return .disabled(reason: reason(deny)) }
        guard canClean else { return .disabled(reason: "Wait for the scan to finish") }
        return .allowed
    }

    static func reason(_ deny: DenyReason) -> String {
        switch deny {
        case .anchor: "Protected system or home folder"
        case .protected: "Protected data (Mail, Keychains, iCloud…)"
        case .outsideRoot: "Outside the scanned folder"
        case .unverifiable, .removeOutsideHome: "Can't verify this item"
        }
    }
}

/// The one keyboard model of map and table. The table moves `selection` itself (arrows, click); the map's hover
/// follows it, so Return and the menus never act on a hover left behind by an earlier pointer position.
struct SpaceMapFocus: Equatable {
    var hover: Int32?
    var selection: Int32?

    /// The pointer wins while it is over a tile; otherwise the selection.
    var current: Int32? { hover ?? selection }

    mutating func move(_ step: SpaceMapLogic.Step, order: [Int32]) -> Bool {
        guard let next = SpaceMapLogic.step(step, from: current, in: order) else { return false }
        hover = next
        selection = next
        return true
    }

    /// The table changed the selection: hover goes with it.
    mutating func selectionChanged() {
        if let selection { hover = selection }
    }
}

/// Memo of `SpaceMapDerived` per input version, so a body re-run (selection, banner) does not re-layout.
@MainActor final class SpaceMapDerivedCache {
    struct Key: Equatable {
        var treeVersion: UInt64?
        var overlayVersion: UInt64?
        var focus: StorageNodeID
        var size: CGSize
        var provenance: SizeProvenance
    }

    private var key: Key?
    private var value = SpaceMapDerived()

    func resolve(_ key: Key, make: () -> SpaceMapDerived) -> SpaceMapDerived {
        if self.key == key { return value }
        value = make()
        self.key = key
        return value
    }
}

// MARK: - View

/// Breadcrumb, treemap card (2/3) and children table card (1/3), one shared hover.
struct SpaceMapView: View {
    let compact: Bool
    /// Width of the area the page gives this view; the 2:1 split is computed from it (no `containerRelativeFrame`:
    /// that measures the window, not the page).
    let contentWidth: CGFloat

    @Environment(StorageModel.self) private var storage
    @Environment(\.presentConfirmDialog) private var confirmDialog
    @State private var mapSize = CGSize(width: 560, height: 360)
    @State private var selection: Int32?
    @State private var cache = SpaceMapDerivedCache()

    var body: some View {
        let map = storage.spaceMap
        let provenance: SizeProvenance = map.overlay == nil ? .estimate : .exact
        let key = SpaceMapDerivedCache.Key(treeVersion: map.tree?.version, overlayVersion: map.overlay?.version,
                                           focus: map.focus, size: mapSize, provenance: provenance)
        let derived = cache.resolve(key) {
            SpaceMapLogic.derive(children: map.children(of: map.focus), tree: map.tree, provenance: provenance,
                                 size: mapSize)
        }
        let tableWidth = max(0, (contentWidth - TTSpace.gridGap) / 3)

        VStack(alignment: .leading, spacing: TTSpace.gridGap) {
            Breadcrumb()
            HStack(alignment: .top, spacing: TTSpace.gridGap) {
                mapCard(derived: derived, provenance: provenance)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                tableCard(rows: derived.rows)
                    .frame(width: tableWidth)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(.previous, order: derived.order) }
        .onKeyPress(.upArrow) { move(.previous, order: derived.order) }
        .onKeyPress(.rightArrow) { move(.next, order: derived.order) }
        .onKeyPress(.downArrow) { move(.next, order: derived.order) }
        .onKeyPress(.return) { drillCurrent(rows: derived.rows) }
        .onKeyPress(.delete) { goUp() }
        .onKeyPress(phases: .down) { press in
            press.key == "[" && press.modifiers == .command ? goUp() : .ignored
        }
        .onChange(of: map.focus) { selection = nil }
        .onChange(of: selection) {
            var focus = focusState
            focus.selectionChanged()
            storage.hover.hoveredID = focus.hover
        }
    }

    private var focusState: SpaceMapFocus { SpaceMapFocus(hover: storage.hover.hoveredID, selection: selection) }

    private var hover: Binding<Int32?> {
        Binding(get: { storage.hover.hoveredID }, set: { storage.hover.hoveredID = $0 })
    }

    private func mapCard(derived: SpaceMapDerived, provenance: SizeProvenance) -> some View {
        let tail = derived.tail
        return TTCard(padding: TTSpace.x12) {
            TTSpaceMap(derived.tiles, hoveredID: hover,
                       // Only the merged tile asks: its value includes layout weights of restricted tiles.
                       formatValue: { _ in
                           tail.knownCount > 0
                               ? StorageFormat.bytes(tail.knownBytes, provenance: provenance, style: .headline)
                               : TTFormat.unavailable
                       },
                       onDrill: drill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGSize.self, of: \.size) { mapSize = $0 }
                .contextMenu { TileMenu(rows: derived.rows, menu: menuActions) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func tableCard(rows: [SpaceMapRow]) -> some View {
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Contents") {
                Text("\(rows.count) \(rows.count == 1 ? "row" : "rows")")
                    .font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
            }
            TTTable(rows: rows, columns: columns, selection: $selection, sort: .constant((column: "size", descending: true)),
                    rowMenu: { row in AnyView(RowMenu(row: row, menu: menuActions)) },
                    style: TTTableStyle(rowHeight: 28, sortsRows: false, emptyMessage: "Empty folder"),
                    onDoubleClick: { row in if let node = row.node, row.drillable { storage.spaceMap.drill(node) } },
                    columnsVersion: compact ? 1 : 0,
                    hover: hover)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var columns: [TTTable<SpaceMapRow>.Column] {
        var cols: [TTTable<SpaceMapRow>.Column] = [
            .init(id: "name", title: "Name", width: .flexible(min: 0)) { row in
                AnyView(Text(row.name).font(TTFont.body12)
                    .foregroundStyle(row.kind == .normal ? TTColor.textPrimary : TTColor.textSecondary)
                    .lineLimit(1).truncationMode(.middle))
            },
            .init(id: "size", title: "Size", width: .fixed(68), alignment: .trailing) { row in
                AnyView(Text(row.sizeText).font(TTFont.body12).monospacedDigit().lineLimit(1)
                    .minimumScaleFactor(0.8).foregroundStyle(TTColor.textSecondary)
                    .help(row.estimated ? StorageFormat.estimateTooltip : ""))
            },
            .init(id: "share", title: "%", width: .fixed(36), alignment: .trailing) { row in
                AnyView(Text(row.shareText).font(TTFont.body12).monospacedDigit().lineLimit(1)
                    .foregroundStyle(TTColor.textSecondary))
            },
        ]
        if !compact {
            cols.append(.init(id: "items", title: "Items", width: .fixed(44), alignment: .trailing) { row in
                AnyView(Text(row.itemsText).font(TTFont.body12).monospacedDigit().lineLimit(1)
                    .foregroundStyle(TTColor.textSecondary))
            })
        }
        return cols
    }

    // MARK: Actions

    private func drill(_ tileID: Int32) {
        let children = storage.spaceMap.children(of: storage.spaceMap.focus)
        guard let child = children.first(where: { $0.tileID == tileID }), case let .node(node) = child.id else { return }
        storage.spaceMap.drill(node)
    }

    private func move(_ step: SpaceMapLogic.Step, order: [Int32]) -> KeyPress.Result {
        var focus = focusState
        guard focus.move(step, order: order) else { return .ignored }
        storage.hover.hoveredID = focus.hover
        selection = focus.selection
        return .handled
    }

    private func drillCurrent(rows: [SpaceMapRow]) -> KeyPress.Result {
        guard let node = SpaceMapLogic.drillTarget(focusState.current, rows: rows) else { return .ignored }
        storage.spaceMap.drill(node)
        return .handled
    }

    private func goUp() -> KeyPress.Result {
        guard storage.spaceMap.focus != 0 else { return .ignored }
        storage.spaceMap.up()
        return .handled
    }

    private var menuActions: SpaceMapMenuActions {
        SpaceMapMenuActions(storage: storage, confirm: confirmDialog)
    }
}

// MARK: - Breadcrumb

private struct Breadcrumb: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        let map = storage.spaceMap
        let chain = map.breadcrumb
        HStack(spacing: TTSpace.x6) {
            ForEach(Array(chain.enumerated()), id: \.element) { index, node in
                let current = index == chain.count - 1
                if index > 0 { Text("›").foregroundStyle(TTColor.textTertiary) }
                let name = name(of: node)
                if current {
                    Text(name).foregroundStyle(TTColor.textPrimary).lineLimit(1).truncationMode(.middle)
                } else {
                    Button(name) { map.drill(node) }
                        .buttonStyle(.plain).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .font(TTFont.body12)
        .frame(minHeight: 20)
        .accessibilityElement(children: .contain)
    }

    private func name(of node: StorageNodeID) -> String {
        if node == 0 { return StorageChrome.rootLabel(storage.root) }
        return storage.spaceMap.path(of: node).split(separator: "/").last.map(String.init) ?? ""
    }
}

// MARK: - Menus

/// What a row/tile menu does, with the model and the shell's confirm dialog captured once.
@MainActor struct SpaceMapMenuActions {
    let storage: StorageModel
    let confirm: ConfirmDialogPresenter?
    private static let log = Logger(subsystem: "dev.telltale", category: "storage")

    func reveal(_ row: SpaceMapRow) {
        guard let node = row.node else { return }
        storage.reveal(path: storage.spaceMap.path(of: node))
    }

    func ignore(_ row: SpaceMapRow) {
        guard let node = row.node else { return }
        storage.ignore(path: storage.spaceMap.path(of: node))
    }

    func trashState(_ row: SpaceMapRow) -> SpaceMapLogic.TrashState {
        SpaceMapLogic.trashState(row: row, policy: storage.policy, tree: storage.spaceMap.tree, canClean: storage.canClean)
    }

    func moveToTrash(_ row: SpaceMapRow) async {
        guard let node = row.node, let item = storage.trashItem(for: node) else { return }
        guard let confirm else {
            Self.log.info("no confirm dialog host, \(item.name, privacy: .private) not moved to the Trash")
            return
        }
        let size = StorageFormat.bytes(row.bytes, provenance: .estimate)
        guard await confirm.confirm(title: "Move “\(item.name)” to Trash?",
                                    message: "\(size) will be moved to the Trash.",
                                    confirmTitle: "Move to Trash") else { return }
        if !storage.clean([item]) {
            Self.log.info("clean refused for \(item.name, privacy: .private)")
        }
    }
}

/// Items for a normal tile or row; restricted and merged entries have no menu.
private struct MenuItems: View {
    let row: SpaceMapRow
    let menu: SpaceMapMenuActions

    var body: some View {
        if row.kind == .normal {
            let trash = menu.trashState(row)
            Button("Reveal in Finder") { menu.reveal(row) }
            switch trash {
            case .allowed:
                Button("Move to Trash…") { Task { await menu.moveToTrash(row) } }
            case let .disabled(reason):
                Button("Move to Trash…") {}.disabled(true).help(reason)
            }
            Button("Ignore") { menu.ignore(row) }
        }
    }
}

private struct RowMenu: View {
    let row: SpaceMapRow
    let menu: SpaceMapMenuActions
    var body: some View { MenuItems(row: row, menu: menu) }
}

/// Targets the tile under the pointer: the map's hover layer tracks it, so the hovered id at right-click is the
/// clicked tile. Reads the hover itself so a menu built before the click does not go stale.
private struct TileMenu: View {
    let rows: [SpaceMapRow]
    let menu: SpaceMapMenuActions

    var body: some View {
        if let id = menu.storage.hover.hoveredID, let row = rows.first(where: { $0.id == id }) {
            MenuItems(row: row, menu: menu)
        }
    }
}
