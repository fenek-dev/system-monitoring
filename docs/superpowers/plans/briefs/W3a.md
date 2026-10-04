# W3a brief — StorageModel (MonitorLive)

Self-contained. Source of truth order: **W1 code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §0, §3, §4 W3a; spec `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` §3.3, §3.4, §4.3, §4.5, §6.5, §7.1). W1 type differs from this brief → code wins; record it in your progress file. Read `docs/superpowers/plans/progress/W1.md` "Interface deltas" first (overlay/accumulator differ from plan §3).

Paths are under `MonitorCore/` unless they start with `docs/`, `scripts/`, `App/`.

## Goal

`@MainActor @Observable StorageModel` that consumes `StorageActions` streams and holds all Storage page state: phase, tree + overlay, Space Map focus/children, Cleanup items with per-app grouped/sorted/cached lines, checked set with running totals via `ReclaimAccumulator`, clean/undo/empty-trash tasks, lifetimes (page switch, window close). Plus two pure helpers W3b reuses so overlay mutation and "reclaimable" have exactly one implementation. No disk access, no AppKit, no `MonitorDiskTools` import (ci grep, `scripts/ci.sh:50-61`).

Depends on W1 only (`MonitorLive` → `MonitorModel`, `Package.swift:43`). W3b (runtime) and W4 (UI) code against the public API you record.

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w3a`, branch `ws/storage-w3a` (orchestrator creates it from `feat/storage`). Work, test, commit only there; rebase on `feat/storage` before handing back. **Do not merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (add `.codegraph/` to `$(git rev-parse --git-common-dir)/info/exclude` if it shows up); else `codegraph sync -q`. `codegraph explore "<symbols>"` before grep.

## Ownership

Own: `Sources/MonitorLive/Storage/**` (new: `StorageModel, ScanProgressState, SpaceMapState, CleanupState, HoverState, CleanupLines, StorageCleanMath`.swift — split further if useful), `Tests/MonitorLiveTests/Storage*`, `docs/superpowers/plans/progress/W3a.md`.

Must not touch: `Sources/MonitorModel/**` (W1, frozen), `Package.swift`, `Sources/MonitorLive/{LiveModel,LiveHistory,RingBuffer}.swift`, everything in `MonitorRuntime`, `MonitorScreens`, `MonitorMocks`, `MonitorDiskTools`, `App/`. Need a change there → local extension in your files + "Requests" in progress file.

## APIs consumed (W1, verified at `64c8bf1`)

- `StorageActions` `Sources/MonitorModel/Storage/StorageServices.swift:28` — all `@MainActor @Sendable`: `scan(ScanRoot, ClassifyOptions) -> AsyncStream<ScanEvent>` `:29`, `cancelScan` `:30`, `loadCached(root, options) async -> (StorageTree, StorageTreeOverlay, CleanupSet)?` `:32`, `loadSummary` `:35`, `reclassify(options) async -> CleanupSet?` `:36`, `policy() -> StoragePolicy` `:38`, `checkInUse([CleanupItem]) async -> Set<Int32>` `:40`, `clean([CleanupItem]) -> AsyncStream<CleanEvent>` `:41`, `cancelClean` `:42`, `undo(UndoRecord)` `:43`, `emptyTrash()` `:44`, `release` `:46`, `availableRoots` `:47`, `hasFullDiskAccess` `:48`, `ignore/unignore/revealInFinder(String)` `:49-51`, `openFDASettings` `:52`; init with defaults `:54`, `.noop` `:99`.
- `ScanEvent` `StorageScan.swift:41` (`.progress`, `.partial(tree)`, `.finished(tree)`, `.classified(set)` up to 3× per scan, `.failed`), `ScanProgress` `:22`, `ScanFailure` `:34`, `ScanRoot` `:3` (`allowsCleanup` `:16`).
- `CleanupItem` `Cleanup.swift:54` (init `:81`; `parentID` is **always nil** from the classifier — grouping is yours), `CleanupSet` `:122` (`treeVersion`, `ownershipResolved`, `privateSizesFinal`, `trashBytes`, `linkGroupSizes` `:130`), `ClassifyOptions` `:143`, `SizeProvenance` `:24` (Comparable), `DeleteMode` `:11`, `SafetyTier` `:7`, `CleanupCategory` `:3`.
- `CleanEvent` `Clean.swift:55` (`.item(CleanItemOutcome)`, `.freed`, `.restored(itemID:finalPath:)`, `.finished(CleanReport)` exactly once), `CleanItemOutcome` `:29` (`detachedBytes`, `removedNodes`, `committedChildren`, `skippedChildren`, `partial`, `skip`, `trashedTo`), `CleanReport` `:63` (`undo` `:72`), `UndoRecord` `:87`, `StorageSummary` `:122`, `SkipReason` `:15`.
- `ReclaimAccumulator` `ReclaimAccumulator.swift:12`: `init(items:tree:overlay:linkSizes:) throws(StorageOverlayError)` `:39`, `insert` `:78`, `remove` `:94`, `bytes` `:112`, `provenance` `:115`, `selectedIDs`/`count` `:74-75`. Immutable over its item list: after items or overlay change, build a fresh one and re-insert the surviving checked ids.
- `StorageTreeOverlay` `StorageTreeOverlay.swift:37`: `init(tree:)` `:91`, `version` `:66`, `remove(_:kind: .deleted|.trashed, in:)` `:112`, `shrink(_:by:in:)` `:138`, `restore(_ RestoredEntry, originalNode:, in:)` `:149`, `size` `:181`, `isRemoved` `:190`, `name` `:196`, `restoredEntries(under:)` `:203`; all reads/mutations throw `.treeMismatch` `:22` on another tree. `RestoredEntry` `:4`.
- `StorageTree` `StorageTree.swift:9`: `version` `:10`, `parent` `:18`, `name` `:96`, `path` `:101`, `size` `:114`, `sortedChildren` `:123`, `isAncestor` `:129`, `lookup(path:)` `:151`, `cutoff` `:173`, `remainderBytes` `:186`. `StoragePolicy` `StoragePolicy.swift:6` (`denyReason(trash:in:)` `:23`).
- Patterns: `@MainActor @Observable public final class LiveModel` `Sources/MonitorLive/LiveModel.swift:24`; observation-isolation test helper `Tests/MonitorLiveTests/LiveModelTests.swift:8-20` (`FireCount`, `observe`); tree fixtures via `StorageTreeBuilder` like `Tests/MonitorModelTests/StorageTreeTests.swift:6-20` + `ReclaimTests.swift:18` (copy into your own `StorageTestSupport.swift`; test targets share no support module; `MonitorLiveTests` has no `MonitorMocks` dep, `Package.swift:94`).

## Public API to implement (record final signatures with file:line — W3b/W4 code against them)

```swift
@MainActor @Observable public final class StorageModel {
  public init(actions: StorageActions, home: String = NSHomeDirectory(), now: @escaping @MainActor () -> Date = { Date() })
  public enum Phase: Equatable { case idle, loadingCache, scanning(hasPrevious: Bool), ready, failed(ScanFailure) }
  public private(set) var phase: Phase; summary: StorageSummary?; hasFullDiskAccess: Bool?; availableRoots: [ScanRoot]; policy: StoragePolicy
  public private(set) var root: ScanRoot            // default .home(home)
  public var classifyOptions: ClassifyOptions       // page sets it from SettingsStore (Live can't import Screens)
  public let progress: ScanProgressState; spaceMap: SpaceMapState; cleanup: CleanupState; hover: HoverState
  // lifetimes
  public func windowDidOpen() async      // loadSummary
  public func pageDidAppear() async      // FDA, roots, loadCached when no tree and not scanning
  public func pageDidDisappear()         // cancels nothing (spec §3.4)
  public func windowDidClose()
  // scan
  public func selectRoot(_:) async; public func startScan(); public func cancelScan()
  public func apply(_ event: ScanEvent)                                   // also used by W4 renders
  public func adopt(tree: StorageTree, overlay: StorageTreeOverlay, cleanup: CleanupSet)   // loadCached path; W4 renders
  public func applyClassifyOptions(_:) async                              // threshold change → reclassify
  // clean
  public func recheckInUse() async -> [CleanupItem]   // §7.1 step 2: newly in-use checked items, now unchecked
  public func clean(_ items: [CleanupItem]) -> Bool   // false if a clean/undo/emptyTrash already runs
  public func trashItem(for node: StorageNodeID) -> CleanupItem?   // Space Map "Move to Trash…" (W4a confirms, then clean([it]))
  public func cancelClean(); public func undoLast() -> Bool; public func emptyTrash() -> Bool
  public func apply(_ event: CleanEvent)
  public func ignore(path:); public func unignore(path:); public func reveal(path:)
}
```
Sub-objects (`@MainActor @Observable public final class`, each observed separately):
- `ScanProgressState`: `progress: ScanProgress?` — the only thing a `.progress` event writes (one assignment per tick).
- `SpaceMapState`: `tree: StorageTree?`, `overlay: StorageTreeOverlay?` (nil while showing a partial tree: sizes from `tree.size`; building an overlay per 3 Hz partial costs O(nodes)), `focus: StorageNodeID`, `breadcrumb: [StorageNodeID]`, `drill(_:)`, `up()`, `children(of:) -> [SpaceMapChild]` cached per (tree.version, overlay?.version, node). `SpaceMapChild { id: SpaceMapChildID (.node(StorageNodeID) | .restored(itemID: Int32)); tileID: Int32 (node id, or `-2 - itemID` for restored; `Int32.min` is TTSpaceMap's "smaller" id); name; bytes: UInt64? (nil = restricted); isDirectory }`, removed nodes excluded, restored entries included, sorted bytes desc then name (TTSpaceMap wants presorted tiles; overlay sizes can reorder `childOrder`).
- `CleanupState`: `items: [CleanupItem]` (current, sizes adjusted after partial cleans), `checked: Set<Int32>`, `inUse: Set<Int32>`, footer `selectedBytes`, `selectedCount`, `selectedProvenance` (≈ when ≠ `.exact`), per-category `CategoryTotal { bytes, provenance, selectedBytes, itemCount, safeCount, reviewCount }`, `category`, `sort: CleanupSort {key: size|name|lastUsed, ascending}`, `expanded: Set<CleanupLineID>`, `showIgnored`, `lines() -> [CleanupLine]`, `toggle(_ CleanupLineID)`, `checkState(_:) -> CheckState (.off/.on/.mixed)`, `cleanProgress: CleanProgress? {total, processed, phase: .detaching/.freeing}`, `skipped: [(CleanupItem, SkipReason)]`, `lastReport: CleanReport?`, `lastUndo: UndoRecord?`, `totalsUnavailable: Bool`.
- `HoverState`: `hoveredID: Int32?` only.
- `StorageCleanMath` (public, pure, used by W3b `StoragePipeline` for the persisted overlay and summary file): `apply(_ outcome: CleanItemOutcome, item: CleanupItem, to: inout StorageTreeOverlay, tree:) throws(StorageOverlayError)`; `applyRestore(itemID:finalPath:item:to:tree:) throws(StorageOverlayError)`; `reclaimable(set:tree:overlay:) throws(StorageOverlayError) -> (bytes: UInt64, provenance: SizeProvenance)` = accumulator over items with `!ignored && mode != .none && category != .trash` (trash is `trashBytes`).

## Rules to encode (decisions fixed by the orchestrator)

- **Checked default** (plan W3a): `tier == .safe && !runningApp && !ignored && mode != .none`. `mode == .none` and ignored items are never checkable. Re-`.classified` / reclassify of the **same tree** keeps the user's checked state **by path** (item ids may differ between passes — verify W2b; key by path either way); new paths get the default.
- **Grouped rows** (classifier leaves `parentID` nil): within the selected category, items with the same `owner?.bundleID` form a group when ≥ 2; group row id `.group(category, bundleID)`, children `.item(id)` shown only when the group id ∈ `expanded`; others top-level `.item(id)`. Group size = Σ child display bytes (`privateBytesExcludingLinks ?? allocBytes`); group check state = on/off/mixed over checkable children; toggling a group: off/mixed → check all checkable, on → uncheck all. Sort groups and items by key, ties by name then id (deterministic). Ignored items filtered unless `showIgnored`. `lines()` cached per (category, sort, expanded, showIgnored, itemsVersion); checked state is **not** in the key — W4b reads `checkState` per row (O(1)), so a toggle never rebuilds lines.
- **Totals:** global footer accumulator + one per category; toggle = `insert`/`remove` on the global and the item's category accumulator (O(item's link groups)). Items/overlay change → fresh accumulators, re-insert surviving checked ids. Accumulator init throws → log `.fault` (`Logger(subsystem: "dev.telltale", category: "storage")`), `totalsUnavailable = true` (footer "—"); never swallow.
- **Scan events:** `startScan` → `phase = .scanning(hasPrevious: tree != nil)`. `.progress` → `progress.progress` only. `.partial` → shown only when there is no previous tree. `.finished(t)` → swap tree, `overlay = StorageTreeOverlay(tree: t)`, focus root, cleanup cleared, `phase = .ready`. `.classified(set)` → ignored unless `set.treeVersion == tree.version`. `.failed` → previous tree kept, `phase = .failed(f)` (`.cancelled` with a previous tree → `.ready`).
- **Clean outcomes** (`StorageCleanMath.apply`): `skip != nil` → nothing changes; item stays, goes to `skipped`. Otherwise by `item.mode`: `.trash` → `remove(node, .trashed)`; `.remove` non-keep-parent → `remove(node, .deleted)`; `.remove` keep-parent → each `removedNodes` → `remove(_, .deleted)`, then `shrink(item.node, by: detachedBytes − Σ sizes of those nodes taken before removal)` (saturating) so folded small files leave too; `.evict` → `shrink(node, by: detachedBytes)` (placeholder stays); `.simctl`/no node → no overlay change. Item leaves the list iff `skip == nil && !(keepParent && skippedChildren > 0)`; a keep-parent partial stays with `allocBytes`/`privateBytesExcludingLinks` reduced by `detachedBytes` and is unchecked. Verify against merged W2c what `partial` means on a non-keep-parent item; record.
- **Undo:** `.restored(itemID, finalPath)` → `restore(RestoredEntry(parent: tree.parent[node] (no node: lookup of the original parent path; nil → log, no overlay change), name: last component of finalPath, bytes: item.allocBytes, itemID), originalNode: item.nodeID)`; item re-added unchecked with `path = finalPath`. Model keeps the cleaned items of the last clean by id for this.
- **Empty Trash:** apply `.item` outcomes as remove-mode deletes (`removedNodes`); on `.finished` drop `.trash`-category items and set `summary?.trashBytes` from the report. Verify outcome shape against merged W2c.
- **Space Map focus:** after any overlay change, a hidden focus moves to the nearest visible ancestor.
- **Lifetimes** (spec §3.4): page switch cancels nothing. `windowDidClose()` → bump `generation`, `actions.cancelScan()`, `actions.cancelClean()` if cleaning, cancel own consumer tasks (the engine keeps draining without a subscriber), `actions.release()`, drop tree/overlay/cleanup/progress, `phase = .idle`, keep `summary`. Every async result (stream event, `loadCached`, `reclassify`, `checkInUse`) is applied only if its captured generation is current — late results after close are dropped.
- **Summary:** home root only; recomputed with `StorageCleanMath.reclaimable` after adopt/classified/clean/undo, `trashBytes` from the set; non-home roots leave it untouched.
- Cleanup actions are refused (`clean` returns false) when `!root.allowsCleanup` unless all items are `.trash` (Space Map trash works on any root, spec §4.4).

## Tasks (commit per task, prefix `feat(storage-model):`)

- [ ] **T1 Sub-objects + `StorageModel` skeleton, phases, `apply(ScanEvent)`, `adopt`.** Accept: builds; scan-phase and observation tests green.
- [ ] **T2 `CleanupState`**: checked defaults, accumulators, toggles, per-category totals, grouped lines + cache, `showIgnored`. Accept: totals + grouping tests green.
- [ ] **T3 Clean/undo/empty-trash**: tasks, `StorageCleanMath`, `cleanProgress`, `skipped`, `lastUndo`, `trashItem(for:)` (category `.largeOld`, tier `.review`, mode `.trash`, id from a negative counter so it never collides with classifier ids, `identity: tree.identity(node)`, `allocBytes` = overlay size, provenance `.estimate`). Accept: clean tests green.
- [ ] **T4 Lifetimes + generation, `SpaceMapState` children/focus, `recheckInUse`, ignore/unignore (mark items locally + `classifyOptions.ignoredPaths`, uncheck; no reclassify).** Accept: lifetime tests green; gate.

## Tests (`Tests/MonitorLiveTests/StorageModelTests.swift` + `StorageTestSupport.swift`; each names its bug)

Drive with test-owned `AsyncStream.makeStream()` continuations returned from `StorageActions` closures; `loadCached`/`checkInUse` stubs await test-controlled continuations. No sleeps: finish the continuation, then `await model.scanTask?.value` (internal task handles, `@testable import MonitorLive`); intermediate states via `apply`. Exact assertions.
- Totals: toggle sequence, then `.item` detach of a checked item sharing a hard-link group with another checked item, then `.restored` → after each step `cleanup.selectedBytes/selectedProvenance` == a fresh `ReclaimAccumulator` over current items/overlay with the same checked ids — bug: drift or double subtract.
- Keep-parent partial outcome (`skippedChildren 1`, `detachedBytes 30`, one removed node of 20): item still listed and unchecked, parent node visible, `overlay.size(parent)` dropped by 30, removed child hidden — bug: UI drops data still on disk / double-subtracts node bytes.
- Rescan: `.partial` while a previous tree exists → `spaceMap.tree` still the previous; `.failed(.io)` → previous kept, phase `.failed`; `.classified` with a stale `treeVersion` ignored — bug: blank map / wrong items on new tree.
- Re-classify keeps checks by path: uncheck a default item, send a second `.classified` (same paths, new ids) → still unchecked — bug: user choices reset mid-scan.
- Grouping: 3 items same bundle ID + 1 other + 1 without owner → one group (collapsed: 1 line; expanded: 1 + 3) and 2 top-level lines in size order; group toggle on mixed checks all checkable children; `mode == .none` child stays unchecked — bug: group checkbox deletes uncheckable rows / unstable order.
- Lifetimes table: page switch (`pageDidDisappear`) then more scan events → applied, `cancelScan` not called; window close → `cancelScan` + `cancelClean` + `release` called once each (spy counters), tree nil, summary kept — bug: page switch kills scan / close leaks tree.
- Late results after close: `loadCached` completes after `windowDidClose` → tree nil, phase `.idle`; clean stream yields `.item` after close → items unchanged — bug: late result resurrects released tree.
- `cancelClean()` → `actions.cancelClean` called, stream's remaining `.item`s and the single `.finished` still applied; `cleanProgress` nil after `.finished` — bug: committed items stay listed / footer stuck on "Cleaning".
- Focus inside a removed subtree moves to nearest visible ancestor — bug: map shows a deleted folder.
- Observation isolation (pattern `LiveModelTests.swift:8-20`): `.progress` doesn't fire observers of `spaceMap`/`cleanup`/`phase`; a toggle doesn't fire `spaceMap` observers — bug: page re-renders at 10 Hz.
- Break-checks (quote red then green): skip the accumulator `remove` on uncheck → totals test red; drop the generation check → late-result test red. Revert.

## Gates

- Iterate: `scripts/test.sh StorageModelTests` (rerun only failed + touched suites).
- Merge gate: `scripts/ci.sh StorageModelTests` (+ any other `Storage*` suite you add in MonitorLiveTests) → `ci.sh: OK`; quote it.

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No `@unchecked` (ci gate `scripts/ci.sh:63-69`), no `as any`/lint disables, no swallowed errors (`try?` on overlay/accumulator calls is swallowing: log `.fault` and surface a state). No AppKit, no `MonitorDiskTools`.
- Comments explain why. No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines: pipe through `tail`/`grep`.
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefix `feat(storage-model):`; message ends with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W3a.md`: Plan / Done (hashes) / Next / Interface deltas (final public signatures with file:line) / Requests / Not verified / Blockers.
- Don't merge; don't run Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, interface deltas, not verified.
