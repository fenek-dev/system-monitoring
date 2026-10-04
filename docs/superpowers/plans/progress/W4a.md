# W4a progress (Storage page shell, Space Map)

## Plan / Done
T0-T5 done in one commit (see `git log` on ws/storage-w4a). Gate: `scripts/build.sh` BUILD SUCCEEDED; `scripts/ci.sh StoragePageLogicTests ShellScreenCatalogTests` -> `ci.sh: OK`.
Break-check (red, reverted): policy check forced to nil -> `trashStateFollowsPolicy` red.

## Interface deltas
- Files: `Pages/Storage/{StoragePage,StorageChrome,SpaceMapView,StorageStates}.swift`; pure helpers `StorageChrome`, `StorageScanButton`, `SpaceMapLogic`, `StorageContentState`.
- Header: page needs `.pageHeaderTrailing` BEFORE the subtitle `.background` hook (later preference modifier wins the merge, chaining `.pageHeader(subtitle:)` after drops it otherwise).
- Row/tile ids = `SpaceMapChild.tileID` (smaller = `TTSpaceMapLayout.smallerID`), so table and map hover share ids.

## Renders checked (id -> what compared)
storage-map[-1100]: padding 20/gap 12, strip (Purgeable dropped at 1100), 2:1 map/table, rows == tiles (9/9), Items column only at 1280, subtitle "~", chip/Scanned/Rescan, no clipping.
storage-nofda[-1100]: banner + strip + map; fixture has no restricted dir at root level (hatch only in UIKit goldens, not seen here).
storage-scanning[-1100]: progress card (files, bytes, middle-truncated path, Cancel), partial map, "N smaller items" row, no "Scanned" text, Reclaimable/Trash "—".
storage, storage-1100 (empty model): rendered with the same code path (idle state).

## Notes / deviations
- Cleanup segment cannot be disabled individually (TTSegmented has no per-option disable): selection ignored for non-home roots + caption shown.
- Root chip drawn manually (TTButtonStyle.chip doubles the Menu bezel); a faint rectangular edge remains in offscreen renders (NSMenu button bezel), not verified in the live app.
- Pause/Settings stay in the header (DESIGN §3.17 lists them); range control is replaced by the page trailing view.
- Restricted tile nominal weight = 2% of siblings; a dwarfed one merges into "N smaller items" like any small tile.

## Not verified
- Live: right-click tile/row menu (TileMenu reads hover at menu build time), double-click drill, keyboard (arrows/Return/⌘[/Backspace), Move to Trash confirm, Choose Folder panel, Scanned label refresh.
- Hover sync render, restricted hatch on this page, cleanup mode (W4b stub), failure/volume-removed states (no catalog entry).
