# W3a — StorageModel progress

Worktree `/Users/arturvorokov/Documents/Projects/telltale-storage-w3a`, branch `ws/storage-w3a` (from `feat/storage` 508449b). Paths under `MonitorCore/`.

## Plan
- [x] T1 sub-objects, `StorageModel`, phases, `apply(ScanEvent)`, `adopt`
- [x] T2 `CleanupState`: defaults, accumulators, toggles, category totals, grouped lines + cache, showIgnored
- [x] T3 clean/undo/empty-trash, `StorageCleanMath`, `trashItem(for:)`
- [x] T4 lifetimes + generation, `SpaceMapState`, `recheckInUse`, ignore/unignore
- [x] Tests (17) + break-checks: skip global accumulator `remove` on uncheck -> footer test red; drop generation check after `loadCached` -> late-load test red; both reverted

## Done
- 9cf85d1 code (all tasks, one commit); tests + progress in the following commit.

## Gate
- `scripts/build.sh` BUILD SUCCEEDED; `scripts/ci.sh StorageModelTests` -> `ci.sh: OK`.

## Interface deltas (files `Sources/MonitorLive/Storage/`)
- `StorageModel.swift`: `init(actions:home:now:)`, `Phase`, `phase/summary/hasFullDiskAccess/availableRoots/policy/root/classifyOptions`, `progress/spaceMap/cleanup/hover`, `windowDidOpen/pageDidAppear/pageDidDisappear/windowDidClose`, `selectRoot/startScan/cancelScan`, `apply(ScanEvent)`, `adopt(tree:overlay:cleanup:)`, `applyClassifyOptions(_:)`, `recheckInUse()`, `clean(_:) -> Bool`, `trashItem(for:)`, `cancelClean/undoLast/emptyTrash`, `apply(CleanEvent)`, `ignore/unignore/reveal(path:)`. As in brief. Internal (tests): `scanTask`, `cleanTask`.
- `SpaceMapState.swift`: `tree, overlay, focus, breadcrumb` (computed, root first), `drill, up, isVisible(_:), children(of:)`, `SpaceMapChild/SpaceMapChildID`. Restored tile ids: itemID >= 0 -> `-2 - itemID` (brief); negative itemIDs (trash items from `trashItem(for:)`) -> `Int32.min + 1 - itemID`, because the brief formula would collide with node ids >= 0.
- `CleanupState.swift`: as brief + `item(_ id:)`, `total(for:)`, `categoryTotals`, `CategoryTotal`, `CleanProgress` (no freedBytes). `skipped` is `[(item:, reason:)]`.
- `CleanupLines.swift`: `CleanupLineID (.group(category, bundleID:) | .item)`, `CleanupLine {id, depth, title, bytes, provenance, item?, owner?, childCount}`, `CleanupSort`, `CheckState`.
- `StorageCleanMath.swift`: public `apply`, `applyRestore`, `reclaimable` as brief.

## Code vs brief
- Verified against `ws/storage-w2c` (2982d62): Empty Trash `.item` outcomes use listing index as `itemID` and carry no `removedNodes`; so the model applies `.item` only when `removedNodes` is present, and on `.finished` (not cancelled) drops `.trash` items, shrinks `<root>/.Trash` node by `report.freedBytes`, and lowers `trashBytes` by `freedBytes` (saturating).
- `partial` is set on `.item` events only for keep-parent; for non-keep-parent deletes it is only set later on report outcomes. The model keys on `keepParent && skippedChildren > 0`, not `partial`.
- `.classified` (and reclassify) of the same tree drops items whose node is already hidden in the overlay (classifier output predates the clean); keep-parent size reductions are not replayed.
- `pageDidAppear` after a cache miss leaves `phase == .idle` (no auto scan); `selectRoot` auto-scans on a miss.
- `selectRoot` is ignored while a clean/undo runs and when the root is unchanged. Root change bumps `generation`.
- `startScan` is a no-op while a scan consumer is running.
- Ignore/unignore on an already-listed path only marks items with that exact path.

## Review round 1 (Codex, all accepted)
- Rebased onto feat/storage (d622d4f). Fixes 1-11 done; 10 new tests (27 total). Break-checks (red then reverted): drop `canScan` guard (exclusion), drop cache epoch check (late cache load), skip pruning of hidden rows (Space Map trash).
- Scan/clean exclusion: `busyReason` (`.scanning`/`.cleaning`), `canScan`, `canClean`; clean/undo/emptyTrash refused while scanning/loading cache, scan/selectRoot refused while cleaning; consumer drops events if the tree version changed since the run began.
- Totals: checked items leave the accumulators at once on removal; everything else (hidden-row prune/revive, size sync from the overlay, full rebuild, summary) is coalesced in `flush()` behind a 50 ms delay (a stream yields once per event, so "next turn" still flushed per event: 2001 flushes measured); direct `apply(CleanEvent)`, `.finished` and run end flush at once.
- Perf (advisory, debug build): 2,000 `.item` events 7.9 s, of which ~6 s is the overlay's own O(nodes) recompute per mutation (W1, frozen); per-event rebuild was 24 s. Target "well under 100 ms" is not reachable without an overlay change (batch mutation API or incremental recompute). Request below.
- `cleanup.itemsVersion` observable; every row lookup reads it. Late `loadCached` dropped after a scan starts (`cacheEpoch`). `.classified` during a clean is held and applied at run end. Item sizes/names/paths always come from the overlay (`presented`), nodeless cleaned items tracked by mode+path. Trash totals: +bytes on committed trash, -bytes on restore and per committed Empty Trash entry. Paths resolve through overlay names (`SpaceMapState.path(of:)`).
- Fix 10 detail: a later classification pass keeps the session-adjusted `trashBytes`.

## Contract changes
- `CleanItemOutcome.path: String?` (default nil, last property/init param) added in MonitorModel `Clean.swift`, exactly as the coordinator specified. W2c must fill `path` (absolute `~/.Trash` entry path) on Empty Trash outcomes; the model maps it via `tree.lookup`.

## Requests
- W1/overlay: `StorageTreeOverlay` mutation is O(nodes) per call; a batch API (`remove(_ nodes:)`) would take 2,000-item cleans from seconds to milliseconds in debug.
- None.

## Not verified
- Real engine streams (W2a/W2c) and W3b wiring; behavior when the engine ends a cancelled scan with `.failed(.cancelled)` vs finishing the stream (both handled, only unit-faked).
- Perf of per-event accumulator rebuild with thousands of items (overlay recompute is O(nodes) per mutation anyway).
- "Late clean `.item` after close" is not tested: tasks are cancelled and apply guards on a nil tree, so the case can't fail independently.

## Blockers
None.
