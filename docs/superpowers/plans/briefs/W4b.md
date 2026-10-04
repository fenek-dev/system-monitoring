# W4b brief — Cleanup mode, clean flow, toast

Self-contained. Source of truth: **merged code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §0, §2, §4 W4b, §6 S5; spec `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` §4.3, **§7.1 flow**, §6.5; `docs/design/DESIGN.md` §3.17 Cleanup / sticky footer / "≈" / Confirm / Toast (`:1183-1188`), §2.29 table checkbox (`:541-547`), §3.12 toast with actions (`:1006`)). No artboards: verify by rendering and **Reading PNGs**. Paths under `MonitorCore/` unless they start with `docs/`, `scripts/`. Lines verified at `feat/storage` `d32c471`; "⚠ W3b" = verify against merged W3b (`briefs/W3b.md`, `progress/W3b.md`); "⚠ P0" = verify against W4c's P0 commit (`progress/W4c.md`).

## Goal

Fill W4c's P0 stubs: `CleanupView(compact:)` (category card + item table + sticky footer) and `CleanToastHost` (page-level toast), plus the clean flow: in-use recheck → confirm → clean → progress → toast (Show / Empty Trash / Undo).

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w4b`, branch `ws/storage-w4b`, from `feat/storage` **after W3b and W4c's P0 commit are merged** (orchestrator creates it). Commit only there; rebase before handing back. **Don't merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (exclude via `$(git rev-parse --git-common-dir)/info/exclude`), else `codegraph sync -q`. `codegraph explore "<symbols>"` before grep.

## Ownership

Own: `Sources/MonitorScreens/Pages/Storage/{CleanupView,CleanupRows,CleanConfirm,CleanToast}.swift` (`CleanupView.swift` exists as the P0 stub; move `CleanToastHost` from it into `CleanToast.swift`; `CleanupRows` = plan's `CleanupLines`, renamed so it doesn't share a name with `Sources/MonitorLive/Storage/CleanupLines.swift`), `Tests/MonitorScreensTests/StorageCleanup*.swift`, `docs/superpowers/plans/progress/W4b.md`. Conditional (only for a defect found in T5 live checks, recorded in the progress file first): `Sources/MonitorUIKit/Components/{TTTable,TTTableCheckbox,TTToast}.swift`, `Tests/MonitorUIKitTests/{TTTableTests,ComponentSnapshotTests}.swift`, goldens `component-table*`, `component-toast*`.

Forbidden: `Pages/Storage/{StoragePage,StorageChrome,SpaceMapView,StorageStates,StorageFormat}.swift`, `Shell/**`, `Popover/**`, `Sources/MonitorLive/**`, `MonitorModel/**`, `MonitorMocks/**`, other UIKit files, `StorageSnapshotTests.swift`, `__Snapshots__/storage-*`. Need a change → Requests.

## APIs consumed

- `StorageModel` (`@Environment(StorageModel.self)` ⚠ W3b) `Sources/MonitorLive/Storage/StorageModel.swift`: `canClean` `:87`, `busyReason` `:79`, `root.allowsCleanup` (`StorageScan.swift:16`), `classifyOptions` `:29`, `applyClassifyOptions(_:) async` `:259`, `recheckInUse() async -> [CleanupItem]` `:320` (unticks newly in-use items, marks `cleanup.inUse`), `clean(_:) -> Bool` `:335`, `cancelClean()` `:368`, `undoLast() -> Bool` `:373`, `emptyTrash() -> Bool` `:380`, `unignore(path:)` `:609`, `reveal(path:)` `:617`.
- `CleanupState` `Sources/MonitorLive/Storage/CleanupState.swift`: `items` `:10`, `checked` `:11`, `inUse` `:13`, `selectedBytes/selectedCount/selectedProvenance` `:16-19`, `categoryTotals` `:20`, `totalsUnavailable` `:22`, `category/sort/expanded/showIgnored` (settable) `:24-27`, `cleanProgress` `:29`, `skipped: [(item:, reason:)]` `:30`, `lastReport` `:31`, `lastUndo` `:32`, `itemsVersion` `:40`, `lines()` `:62` (cached, sorted, grouped), `checkState(_:)` `:78`, `item(_:)` `:90`, `total(for:)` `:95`, `toggle(_:)` `:99` (group toggle checks all when mixed).
- `Sources/MonitorLive/Storage/CleanupLines.swift`: `CleanupLineID (.group(category, bundleID:) | .item(id))` `:4-8`, `CheckState` `:10`, `CleanupSort {key: .size/.name/.lastUsed, ascending}` `:14-26`, `CleanupLine {id, depth, title, bytes, provenance, item?, owner?, childCount}` `:28-40`, `CategoryTotal {bytes, provenance, selectedBytes, itemCount, safeCount, reviewCount}` `:42-51`, `CleanProgress {total, processed, phase: .detaching/.freeing}` `:53-61`. `isCheckable` / `displayBytes` `:64-66` are **internal** — orchestrator prerequisite makes them public (see W4c brief); if not, request it, don't re-implement.
- Model types: `CleanupItem` `Sources/MonitorModel/Storage/Cleanup.swift:54` (`tier` `:62`, `mode` `:63`, `lastUsed` `:73`, `owner` `:74`, `runningApp` `:75`, `ignored` `:78`, `note` `:79`), `DeleteMode` `:11-21` (`.none` = info only, e.g. Docker), `SafetyTier` `:7`, `OwnerApp {bundleID, name, appPath}` `:42`, `ClassifyOptions.largeBytes` `:146` (default 500 MB `:152`); `CleanReport {freedBytes, trashedBytes, evictedBytes, outcomes, cancelled, stagingLeftovers, undo}` `Clean.swift:67-88`; `SkipReason` `:15-27`; `CleanItemOutcome.skip` `:38`.
- UIKit: `TTTable` full init `Sources/MonitorUIKit/Components/TTTable.swift:70-73` (`children:`/`hasChildren:` for groups, `onSpace:`, `onDoubleClick:`, `hover:`, `rowMenu:`, `style:`), Space handler `:214-215`, row tap select `:272` + double-click `:273`, `TTTableStyle(sortsRows: false, headerSorts: true…)` precedent `.processes` `:437`; `TTTableCheckbox(_ state: .off/.on/.mixed, disabledReason:toggle:)` `Components/TTTableCheckbox.swift:10,19`, `columnWidth` 24 `:12`; `TTToast(_ text, actions: [.show(f), .emptyTrash(f), .undo(f)])` `Components/TTToast.swift:9-13,50`, `TTToast.lifetime(hasUndo:)` `:39` (10 s with Undo, else 4 s); toast host precedents `Pages/W5aPageSupport.swift:437-445`, `Popover/PopoverRoot.swift:37-41`; `TTBadge(_:level:)` `Components/TTBadge.swift:11`; `TTAppTile(identity:name:size:)` `Components/TTAppTile.swift:17` (letter tile in snapshots `:68`; `AppIdentity(key:displayName:bundlePath:)` `Sources/MonitorModel/Basics/Identifiers.swift:61`, `AppKey(kind: .app, id: bundleID)`); `TTSegmented` `Components/TTSegmented.swift:12`; `TTCard`/`TTCardHeader(_:icon:trailing:)` `Components/TTCard.swift:10,47`.
- Shell: `@Environment(\.presentConfirmDialog)` → `confirm(title:message:confirmTitle:) async -> Bool` `Shell/ConfirmDialogHost.swift:49,66` (nil outside a dashboard window → treat as "not confirmed"); multi-line message supported (`TTConfirmDialog.swift:52-56`, wrapping `Text`). Settings `storage.largeThreshold` + `classifyOptions(now:)` ⚠ W3b (`SettingsStore`).
- P0 (⚠ P0): `StorageFormat.bytes(_:provenance:style:)`, `.estimateTooltip`, `.selection(bytes:provenance:count:)`; `CleanupView(compact:)` / `CleanToastHost()` signatures are fixed (W4a places them).
- Mocks for tests: `MockStorageState.make(.cleanup)` `Sources/MonitorMocks/MockStorageState.swift:27` (21 items, ids 1–21 by category; in use: 4; running app: 1; ignored: 6; same owner 2+3 and 13+14; evict 12; Docker `.none` 19; simctl 20; keep-parent 1–6, 13, 14, 18, 21 — `progress/W3c.md`), home `/Users/demo`; `MockDataProvider(scenario:).storageActions(log:state:)` `Sources/MonitorMocks/MockDataProvider.swift:274` (`checkInUse` → `state.inUseIDs`; `clean` logs each item **on call** as `.clean`/`.trash`); `ActionLog.storageItemIDs` `ActionLog.swift:38`, kinds `:9-11`.

## Design decisions (fixed)

- **Layout** (`grid3`, DESIGN §3.17): left card (1 col) = categories User Caches · Leftovers · Large & Old · Developer · Trash; row: name, total (`StorageFormat.bytes(total.bytes, total.provenance)`), selected, tier mix (`Safe n` / `Review n` badges); click sets `cleanup.category`. Right card (span 2) = items table of `cleanup.lines()`; card header: category title + (Large & Old) threshold `TTSegmented` 100 MB / 500 MB / 1 GB / 5 GB → settings + `await storage.applyClassifyOptions(…)` + `Show ignored` toggle (`cleanup.showIgnored`). Sticky footer (height 44, top `separator`, outside the scroll) under the grid.
- **Columns**: checkbox (`TTTableCheckbox.columnWidth`; state from `checkState`; `disabledReason` "Shown for information; Warden doesn't delete this" for `.none`, "Ignored" for ignored rows) · tile + name (group: owner `TTAppTile`; item: owner tile if any, else file/folder glyph) · size (`StorageFormat.bytes`, "≈" tooltip) · tier badge · `In use` badge (`cleanup.inUse` or `runningApp`) · last used (`MMM d, yyyy`-style per locale, "—" if nil; compact → column dropped first). Ignored rows (when shown) show `Unignore` (`storage.unignore(path:)`); iCloud (`mode == .evict`) rows say `Remove Download`. Group rows: `childCount`, expand via `cleanup.expanded`; **double-click on a group toggles expansion; on an item reveals it in Finder**.
- **Interaction**: click on the row text selects (TTTable); clicking the checkbox toggles **without** selecting/activating the row; Space on the selected row → `cleanup.toggle(row.id)` (`onSpace`); table `sortsRows: false`, header sort writes `cleanup.sort`.
- **Footer**: idle → `StorageFormat.selection(bytes: selectedBytes, provenance: selectedProvenance, count: selectedCount)` + `Clean…` (`.smallPrimary`, disabled when `selectedCount == 0 || !storage.canClean`, keyboard-reachable). `cleanProgress.phase == .detaching` → `Cleaning {processed}/{total}…` + `Cancel` (`storage.cancelClean()`); `.freeing` → `Freeing…`. In-use notice (after step 2) inline in the footer: "{n} items in use were unticked." until the next selection change.
- **In-use prewarm** (spikes §5): `.task(id: root)` when Cleanup appears → `await storage.recheckInUse()` (fills `In use` badges; it also unticks — that is the §7.1 rule).
- **Clean flow** (`CleanConfirm`, spec §7.1), one async function with the dialog injected (`confirm: (title, message) async -> Bool`) so tests drive it: 1 `guard storage.canClean` · 2 `let newlyInUse = await storage.recheckInUse()` · 3 `items = cleanup.items` filtered by `cleanup.checked`; empty → return (notice only) · 4 message via a pure builder · 5 `await confirm(…)`; false/nil dialog → return, nothing called · 6 `storage.clean(items)`; false → log `.info` and return.
- **Message builder** (pure, DESIGN §3.17 Confirm): title `Clean {≈}{total}?`; lines only for non-zero groups — "Delete permanently: {X} (caches, build data)" (`.remove` + `.simctl`), "Move to Trash: {Y} (leftovers, large files)" (`.trash`), "Remove downloads: {Z} (iCloud)" (`.evict`); then, if any items are in use (`newlyInUse`), "In use, skipped:" + at most 5 names, then "+{N} more"; confirm title `Clean`. Sizes via `displayBytes`; "≈" when any contributing item is not `.exact`.
- **Toast** (`CleanToastHost`, DESIGN §3.12 `:1006`): shows when a run finishes (`cleanup.lastReport` changes to non-nil; key the `.task` on a run counter you keep, not on the report value). Text: `Freed {freed}` (freedBytes + evictedBytes) and/or `Moved {trashed} to Trash` joined by " · "; cancelled run → prefix "Stopped. "; nothing freed/trashed → "Nothing was cleaned". **Trashed bytes never count as freed.** Actions in order: `Show` only when `cleanup.skipped` non-empty (sheet listing name + reason copy per `SkipReason`; toast pinned while the sheet is open) · `Empty Trash` only when `trashedBytes > 0` → confirm (`Empty Trash?` / "Permanently delete everything in the Trash ({trash size})." / `Empty Trash`) → `storage.emptyTrash()` · `Undo` only when `cleanup.lastUndo` belongs to this run → `storage.undoLast()`. Lifetime `TTToast.lifetime(hasUndo:)`; any action except Show dismisses. No Finder "Put Back" wording anywhere.

## Tasks (commit per task; prefix `feat(storage-ui):`)

- [ ] **T0** Verify ⚠ W3b/⚠ P0 + prerequisite (public `isCheckable`/`displayBytes`); record under "Interface deltas". Accept: filled before code.
- [ ] **T1 `CleanupRows`** (row model wrapping `CleanupLine` + check state + in-use, `Equatable` incl. checked so a toggle redraws one row) + **`CleanupView`** cards and table. Accept: `scripts/render.sh storage-cleanup calm` and `storage-cleanup-1100 calm` → Read: categories, groups, badges, disabled Docker checkbox, ignored row hidden by default.
- [ ] **T2 Footer + threshold + Show ignored/Unignore.** Accept: renders Read; footer "≈" when selection includes estimates.
- [ ] **T3 `CleanConfirm`** flow + message builder. Accept: tests below.
- [ ] **T4 `CleanToast`** (`CleanToastHost`, skip sheet, Empty Trash confirm). Accept: tests below.
- [ ] **T5 Live checks** (`scripts/build.sh`; `scripts/run.sh --mock calm --mock-storage cleanup --open-dashboard storage`, ⚠ W4c option name): click row text selects; checkbox click toggles without selecting; Space toggles; group double-click expands; Clean… → in-use notice for Chrome (id 4) → confirm dialog lines → toast with Show/Empty Trash/Undo; Empty Trash asks first. Quote observations; anything you can't drive → "Not verified". A defect in TTTable/TTTableCheckbox/TTToast → conditional ownership, fix, re-record + Read affected `component-*` goldens and re-render sibling users (Processes `processes calm`, Disk `disk calm`, popover).

## Tests (`StorageCleanupTests`, mock actions + `ActionLog`; each names its bug)

- Cancelled confirm (`confirm` returns false) → `log.storageItemIDs == []` — bug: delete without confirm.
- No dialog available (nil presenter) → nothing logged — bug: clean proceeds outside a window.
- Confirmed → logged ids == checked ids minus newly in-use (fixture: check id 4 explicitly, expect it unticked and absent) — bug: deleting an in-use item.
- Toast Empty Trash with confirm cancelled → no `.emptyTrash` record; confirmed → exactly one — bug: Empty Trash without confirm.
- Message builder, one parametrized test: 7 in-use names → 5 + "+2 more"; 5 → no "+N"; mixed remove/trash/evict → exactly the three lines with exact sizes; estimate → "≈" in title.
- Toast text, one parametrized test: (freed, trashed, evicted, cancelled) → exact string; trashed-only report never contains "Freed" — bug: trashed bytes reported as freed.
- Snapshot tests: **0** new here (goldens are W4-final's `storage-cleanup[-1100]`; conditional `component-*` re-records only).
- Break-checks (quote red, revert): skip the `confirm` result check → first test red; drop the in-use filter → third test red.

## Gates

- Iterate: `scripts/test.sh StorageCleanupTests`; renders Read.
- Final: `scripts/ci.sh StorageCleanupTests ShellScreenCatalogTests` (+ `TTTableTests ComponentSnapshotTests` if you touched UIKit) → `ci.sh: OK`; quote it.

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No `@unchecked` outside `MonitorMocks` (`scripts/ci.sh:63-69`), no `as any`/lint disables/swallowed errors. No `import MonitorDiskTools` (`scripts/ci.sh:50-61`). No `Date()` in view bodies (use `\.now`).
- Never duplicate model logic (totals, check rules, reclaim math) in the view: read `CleanupState`.
- Comments explain why; match density. No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines (`tail`/`grep`).
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefix `feat(storage-ui):`; message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W4b.md`: Plan / Done (hashes) / Next / Interface deltas / Live checks (observed) / Goldens changed / Requests / Not verified / Blockers.
- Don't merge; no Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, live checks, deltas, not verified.
