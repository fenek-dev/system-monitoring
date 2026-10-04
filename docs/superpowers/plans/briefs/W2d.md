# W2d brief — UIKit: TTSpaceMap, TreemapLayout, TTTable hover/checkbox, TTToast actions

Self-contained. Source of truth order: **W1 code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §4 W2d; spec `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` §4.7; DESIGN `docs/design/DESIGN.md` §2.28/§2.29/§3.12/§3.17). If a W1 type differs from this brief, the code wins; record the mismatch in your progress file. A Codex review of W1 may land small fixes before you start — re-read the cited files.

Paths below are under `MonitorCore/` unless they start with `docs/`, `scripts/`.

## Goal

Generic UIKit pieces the Storage page (W4) needs, with no storage-model coupling: a one-`Canvas` space map with cached rects and hit testing, a presorted O(1)-step squarify, table hover binding + checkbox cell, toast with Show / Empty Trash / Undo. Plus: widen the `icons` gallery strip that clips the last icons.

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w2d`, branch `ws/storage-w2d` (created from `feat/storage` by the orchestrator after W1 merged). Work, test, commit only there. Rebase on `feat/storage` before handing back. **Do not merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (if `git status` then lists `.codegraph/`, add it to `$(git rev-parse --git-common-dir)/info/exclude`); else `codegraph sync -q`. Use `codegraph explore "<symbols>"` before grep.

## Ownership

Own: `Sources/MonitorUIKit/**` **except** `Tokens/TTIcon.swift`, `Gallery/GalleryPopover.swift`, `Environment/EnvironmentValues+Telltale.swift`; `Tests/MonitorUIKitTests/**` (+ `__Snapshots__`); `docs/superpowers/plans/progress/W2d.md`.
New files: `Treemap/TTSpaceMap.swift`, `Treemap/SpaceMapHitTest.swift`, `Components/TTTableCheckbox.swift`, `Tests/MonitorUIKitTests/{TreemapBaseline,SpaceMapHitTestTests}.swift`.

Must not touch: the three excluded UIKit files above, anything outside `MonitorUIKit`/`MonitorUIKitTests` (`MonitorScreens` call sites of `TTToast`/`TTTable` must keep compiling **unchanged**), `Package.swift`, `scripts/**`, other docs.
Escalation: a needed change in a file you don't own → local extension in your own files, record under "Requests" in your progress file.

## Existing code you build on (verified at W1 head)

- `TreemapLayout.squarify(_:otherIndex:in:)` `Sources/MonitorUIKit/Treemap/TreemapLayout.swift:13`; descending sort `:41`; greedy row loop `:46-64`; `worstRatio` rescans the row each growth step `:69-77` (O(k²)); `layoutRow` `:80`. Used by `TTTreemap` `Treemap/TTTreemap.swift:65` — that entry point and its output must stay identical.
- Existing `TreemapLayoutTests` `Tests/MonitorUIKitTests/TreemapLayoutTests.swift:7` (seeded `SplitMix` RNG `:10`, invariants helper `:23`).
- `TTChartCanvas` `Charts/TTAreaChart.swift:115` (Canvas precedent).
- `TTTable` `Components/TTTable.swift:14`: inits `:56`, `:64` (full); private `TableRow` `:293` with per-row `@State hovering` `:306`, `==` `:309-314` (no hover term), `active` `:318`, `.onHover` `:347`; `TTTableStyle` `:373`, `.processes` `:402` (`sortsRows: false`). Tests `Tests/MonitorUIKitTests/TTTableTests.swift:8`.
- `TTToast` `Components/TTToast.swift:6`: `lifetime = .seconds(4)` `:10`, `init(_:undo:)` `:12`, Undo as `TTLink` `:23`. Call sites that must compile unchanged: `MonitorScreens/Popover/PopoverRoot.swift:37,41`, `MonitorScreens/Pages/W5aPageSupport.swift:437,443`, `MonitorScreens/Pages/ThermalsPage.swift:865,869`; gallery `Gallery/GalleryOverlays.swift:11,41`.
- Buttons: `TTButton.swift:7` (`.smallSecondary`), `TTLink` `:190`.
- Confirm dialog: no change — already multi-line (`Components/TTConfirmDialog.swift:52`).
- Gallery: items `Gallery/GallerySamples.swift:7-21`; `icons` item `:9` is 560×40; `IconsSample` `:28-36` = `TTIconName.allCases` (25 cases, `Tokens/TTIcon.swift:6-9`) × 16 pt, spacing 8, padding 12 → needs 25·16 + 24·8 + 24 = **616 pt**; at 560 `overlay` and `volume` are clipped.
- Snapshot ids `Tests/MonitorUIKitTests/ComponentSnapshotTests.swift:11-14`; record with `TELLTALE_RECORD=1 scripts/test.sh ComponentSnapshotTests` (`Sources/MonitorSnapshotTesting/AssertSnapshot.swift:20`); `ci.sh` runs strict (`scripts/ci.sh:8`).
- DESIGN: Space Map variant `docs/design/DESIGN.md:539` (presorted, cut < 0.5 % **or** tile < 24×16 pt, cap 200, "N smaller items" laid out last like Other, `fillTrack`, `caption textSecondary`, not drillable; restricted = cached diagonal hatch over `fillTrack`, size "—", tooltip "Needs Full Disk Access"; fill `disk` @ 0.28, hover @ 0.45; no drill animation). Table checkbox `:543`. Toast with actions `:1006`. Storage screen `:1174`; "≈" rule `:1185`.

## Tasks (commit per task, prefix `feat(uikit):`)

- [ ] **T1 Baseline (first commit, before touching `TreemapLayout`)**: a throwaway generator test prints `squarify` output for 200 seeded inputs (vary count 0–60, values incl. ties/zeros/NaN, `otherIndex` nil/some, rect aspect wide/tall) as Swift literals → `Tests/MonitorUIKitTests/TreemapBaseline.swift` (inputs + expected rects). Delete the generator before committing. No Package change.
- [ ] **T2 `TreemapLayout.squarify(presorted:otherIndex:in:)`** (input already descending; skip `:41`) and incremental row min/max: `worst = max(1, w²·maxA/s², s²/(w²·minA))` over positive areas — mathematically and in IEEE terms the same values as `worstRatio` (division/multiplication by positive constants is monotone), so layouts must match bit-for-bit; ±1e-9 in the test. Old entry point delegates after its sort. Accept: `TreemapLayoutTests` green incl. baseline.
- [ ] **T3 `SpaceMapHitTest`**: pure struct over cached `[(id: Int32, rect: CGRect)]`: `tile(at: CGPoint) -> Int32?`; half-open rects (`minX ≤ x < maxX`), gutter (1-pt inset per tile, as `TTTreemap`) → nil; "smaller" tile returns its id (caller treats it as non-drillable).
- [ ] **T4 `TTSpaceMap`** (spec §4.7): input tiles `{id: Int32, value: Double, label: String, valueText: String, kind: .normal | .smaller | .restricted}` presorted by value, plus `hoveredID: Binding<Int32?>`, `onDrill: (Int32) -> Void`. Layout once per (tiles identity/version, size) via `squarify(presorted:)`, apply the < 24×16 pt cut + cap 200 by merging the tail into the smaller tile (expose the capped result so the page's children table shows the same set — DESIGN `:539`). One `Canvas` draws all tiles and labels (labels only where they fit); hover highlight in a separate overlay layer that reads only `hoveredID`; one `onContinuousHover` hit-testing the cached rects; one tooltip; hatch pattern built once and cached; no animation on drill; `.accessibilityChildren` with one element per tile "{name}, {size}, {share}%". Generic: no `MonitorModel` storage types.
- [ ] **T5 `TTTable` hover + checkbox**: optional `hover: Binding<Row.ID?>` added to the full init `:64` (default nil keeps today's per-row `@State` behavior so existing call sites compile unchanged); when given, `TableRow` gets `isHovered: Bool` included in `==` and sets the binding from `.onHover`, so a hover change re-evaluates two rows. `TTTableCheckbox` (DESIGN `:543`): `Toggle(.checkbox)` tinted `accent`, 16 wide (24 cell), states on/off/mixed, disabled at `opacity.disabled` with a reason tooltip; Space toggles the focused row; clicking never selects/expands the row.
- [ ] **T6 `TTToast` actions**: keep `lifetime` (4 s) and `init(_:undo:)` source-compatible; add `static let undoLifetime: Duration = .seconds(10)`, `static func lifetime(hasUndo: Bool) -> Duration`, `TTToast.Action` (`show`, `emptyTrash`, `undo`, each with a closure) and `init(_ text:, actions: [Action])`. Render order text · Show · Empty Trash · Undo (whatever order the caller passes), each `small secondary`, gap 8. Visibility rules (Show only when skips > 0, Empty Trash only when trashed > 0, Undo only for trash undo) are the caller's (W4b): document on the init; pinning while Show's sheet is open is the caller's timer.
- [ ] **T7 Gallery + goldens**: new items `space-map`, `space-map-restricted`, `table-checkbox`, `toast-actions` (sample data deterministic) appended to `ComponentSnapshotTests.ids` `:11-14`; widen `icons` (`GallerySamples.swift:9`) to **640×40**. Record `TELLTALE_RECORD=1 scripts/test.sh ComponentSnapshotTests`, then **Read every new/changed PNG** in `Tests/MonitorUIKitTests/__Snapshots__/` and compare with DESIGN `:539`/`:543`/`:1006`; `component-icons.png` must show all 25 icons incl. `overlay`, `volume`. Re-recording also rewrites `component-row-action`, `component-timeline-card`, `component-top-processes` with pixel noise (W1 progress `docs/superpowers/plans/progress/W1.md:44`) — `git checkout` those three, then confirm the strict run is green.

## Tests (each catches a named bug; exact; deterministic)

- `TreemapLayoutTests`: presorted path and old path vs `TreemapBaseline` for all 200 inputs (±1e-9) — bug: refactor changes layouts.
- `SpaceMapHitTestTests` (table): point on a shared edge → the tile whose `minX/minY` it is; point in the 1-pt gutter → nil; point in the "smaller" tile → its id; outside → nil — bug: wrong tile hovered/drilled.
- Hover redraw: no body-evaluation hook in `TTTable` → **no test** (plan §7 note); advisory only.
- Snapshots: the 4 new gallery items + re-recorded `component-icons` (after visual check).
- Perf (advisory, report number): 10k-child presorted layout with cutoff + cap < 2 ms.
- Break-check: in the incremental step use `minA` where `maxA` belongs once → baseline test red; revert. Quote both runs.

## Gates

- Iterate: `scripts/test.sh TreemapLayoutTests` etc.
- Merge gate: `scripts/ci.sh TreemapLayoutTests SpaceMapHitTestTests TTTableTests ComponentSnapshotTests` → `ci.sh: OK`; quote it (builds the app too, so `MonitorScreens` call sites are checked).
- UI verification: `scripts/render.sh --component <id>` (`scripts/render.sh:4`) → Read the PNG under `MonitorCore/.build/renders/`. State in progress what you could not see (hover, tooltip, keyboard — no running page until W4).

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No `@unchecked`, no `as any`/lint disables, no swallowed errors.
- Comments explain why, not what; match surrounding density. No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines: pipe through `tail`/`grep`.
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefix `feat(uikit):`; message ends with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W2d.md`: Plan / Done (hashes) / Next / Interface deltas (final `TTSpaceMap`, `TTTable` hover, `TTToast.Action`, `TTTableCheckbox` signatures with file:line — W4 codes against these) / goldens changed / Requests / Not verified / Blockers.
- Don't merge; don't run Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, goldens changed, perf number, interface deltas, not verified.
