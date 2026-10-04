# W2d progress (branch ws/storage-w2d)

## Plan / Done
- T1 baseline fixture `1ed17da` (TreemapBaseline.swift, 200 seeded cases from pre-refactor squarify)
- T2 presorted + O(1) row ratio `66f145f`
- T3+T4 SpaceMapHitTest, TTSpaceMap, TTSpaceMapLayout `7c8c159`
- T5 TTTable hover/onSpace + TTTableCheckbox (next commit)
- T6 TTToast actions, T7 gallery + goldens (final commit)

## Interface deltas (W4 codes against these)
- `TTSpaceMap(_ tiles: [TTSpaceMapTile], hoveredID: Binding<Int32?>, formatValue: (Double)->String = bytes, onDrill: (Int32)->Void)` Treemap/TTSpaceMap.swift:112,120. Tiles presorted desc. `onDrill` fires only for `.normal` tiles.
- `TTSpaceMapTile(id: Int32, value:, label:, valueText:, kind: .normal/.smaller/.restricted)` TTSpaceMap.swift:3. Input should be normal/restricted; `.smaller` is produced.
- `TTSpaceMapLayout.make(_ tiles, in: CGSize)` -> `placed`, `shown`, `smallerCount`, `smallerValue`, `total`; consts `maxTiles` 200, `minShare` 0.005, `minTileSize` 24x16, `smallerID` = Int32.min. Same call (with the map's size) gives the children-table set.
- Restricted tiles have no size: caller passes a nominal `value` weight (laid out by it, can be cut into "smaller" if under 0.5 %); `valueText` "—".
- `TTTable.init(..., hasChildren:, hover: Binding<Row.ID?>? = nil, onSpace: ((Row)->Void)? = nil)` TTTable.swift:59. Space handled via `.onKeyPress(.space)` on the selected row.
- `TTTableCheckbox(_ state: .off/.on/.mixed, disabledReason: String? = nil, toggle: () -> Void)`, `TTTableCheckbox.columnWidth` 24. TTTableCheckbox.swift:13-20.
- `TTToast.init(_ text, actions: [TTToast.Action])`, `Action` = `.show(f) / .emptyTrash(f) / .undo(f)`; `TTToast.undoLifetime` 10 s, `TTToast.lifetime(hasUndo:)`; `lifetime` (4 s) and `init(_:undo:)` unchanged. TTToast.swift:9,37,39,50.
- Gallery: `GalleryStorage.items` (new file Gallery/GalleryStorage.swift), appended in GallerySamples.

## Deviations
- Singular label "1 smaller item" (DESIGN says "{n} smaller items").
- Cap 200 is unreachable in practice (0.5 % cut keeps <= 200 tiles) but kept per spec.
- Hit test: edge-ownership tested with inset 0; default inset 1 makes shared edges gutter (nil), per both brief rules.
- TTTable `onSpace` param added (brief: Space toggles focused row; needs a table-level key handler).

## Goldens changed
- component-icons (640 wide, all 25 icons visible incl. overlay, volume).
- New: component-space-map, -space-map-restricted, -table-checkbox, -toast-actions.
- row-action / timeline-card / top-processes: re-record noise reverted with git checkout.

## Requests
- none

## Not verified
- Live hover/tooltip/click/Space/keyboard (no running page until W4); that a click on the checkbox does not also select the row (Toggle should consume it, unconfirmed).
- Checkbox accent tint: snapshot window is inactive so boxes render gray/white.
- Perf 10k layout: ~2.3 ms in debug build (advisory).

## Blockers
- none
