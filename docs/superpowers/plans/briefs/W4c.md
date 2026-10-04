# W4c brief — wave scaffold (P0), sidebar value, Disk-flyout link, ScreenCatalog + launch options

Self-contained. Source of truth: **merged code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §0, §2, §4 W4c/W4-final; spec `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` §4.5–4.6; `docs/design/DESIGN.md` §3.0 sidebar line "Storage", §3.1 "Free up space…" (`DESIGN.md:633`), §3.17, §5.8). Paths under `MonitorCore/` unless they start with `App/`, `docs/`, `scripts/`. Line numbers verified at `feat/storage` `d32c471`; "⚠ W3b" = written before W3b merged, verify against merged W3b first (brief `docs/superpowers/plans/briefs/W3b.md`, progress `progress/W3b.md` if present).

## Goal

1. **P0 scaffold (T0–T2), merged first**: shared Storage formatting, the `CleanupView` stub W4b fills, and the 10 storage `ScreenCatalog` entries — W4a and W4b branch only after P0 is on `feat/storage`, so every stream can render every state.
2. Sidebar Storage value `{n} GB reclaimable` after a home scan, else free space.
3. Disk flyout "Free up space…" / "Free up {X}…" link → dashboard on Storage.
4. `--mock-storage <kind>` launch option so W4-final can screenshot every mock state in the running app.

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w4c`, branch `ws/storage-w4c`, from `feat/storage` **after W3b merged** (orchestrator creates it). Commit only there; rebase on `feat/storage` before handing back. **Don't merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (add `.codegraph/` to `$(git rev-parse --git-common-dir)/info/exclude`), else `codegraph sync -q`. `codegraph explore "<symbols>"` before grep.
- **P0 hand-off**: after T2 is green, commit, write "P0 ready <hash>" in your progress file and report it (≤5 lines) — orchestrator merges `ws/storage-w4c` at that commit, then creates W4a/W4b. You continue T3+ on the same branch.

## Prerequisite (orchestrator, before T2) — W3a-owned file

Catalog states are built synchronously (renders can't await; `.task` never runs in `SnapshotRenderer`), but `StorageModel.hasFullDiskAccess`/`availableRoots` are `private(set)` and only set by async `pageDidAppear()` (`Sources/MonitorLive/Storage/StorageModel.swift:24-25,106-111`). Orchestrator adds to `StorageModel.swift` a public synchronous seed, e.g. `public func seedAccess(hasFullDiskAccess: Bool, roots: [ScanRoot])` (name ⚠ verify), and makes `CleanupItem.isCheckable` / `displayBytes` public (`Sources/MonitorLive/Storage/CleanupLines.swift:64-66`, needed by W4b). Missing at T2 → record under Requests; build `noFDA` without the banner and flag it.

## Ownership

Own (W4): `Sources/MonitorScreens/Pages/Storage/StorageFormat.swift` (new; frozen after P0, later changes via orchestrator), `Sources/MonitorScreens/Pages/Storage/CleanupView.swift` (**stub only; ownership passes to W4b at P0 merge** — never touch it after), `Sources/MonitorScreens/Shell/{ScreenCatalog,LaunchOptions,Sidebar}.swift`, `Sources/MonitorScreens/Popover/{FlyoutView,FlyoutModel,PopoverModel,PopoverRoot,PopoverRowView}.swift`, `Sources/MonitorRuntime/{TelltaleRuntime,MockPipeline}.swift`, `App/Sources/Composition/AppEnvironment.swift`, `Tests/MonitorScreensTests/{StorageFormatTests,ShellCompositionTests,PopoverTests,FlyoutTests}.swift`, `Tests/MonitorScreensTests/ShellConfirmDialogTests.swift` (**only** `ShellSidebarValueTests`, `:152-…`), goldens `__Snapshots__/{popover-*,flyout-*,shell-sidebar-calm}.png`, `docs/superpowers/plans/progress/W4c.md`.

Forbidden: `Pages/Storage/{StoragePage,StorageChrome,SpaceMapView,StorageStates}.swift` (W4a), `Pages/Storage/{CleanupRows,CleanConfirm,CleanToast}.swift` (W4b), `Tests/MonitorScreensTests/{StorageSnapshotTests,StorageCleanup*,StoragePage*}.swift`, `__Snapshots__/storage-*` (W4-final/W4a/W4b), `Sources/MonitorLive/**`, `Sources/MonitorModel/**`, `Sources/MonitorMocks/**`, `Sources/MonitorUIKit/**`, `Package.swift`. Need a change there → Requests.

## APIs consumed (verified unless ⚠)

- `StorageModel` `Sources/MonitorLive/Storage/StorageModel.swift:10`: `init(actions:home:now:)` `:89`, `summary` `:22`, `phase` `:21` (`.scanning(hasPrevious:)` `:16`), `startScan()` `:192` (sets `.scanning` synchronously), `apply(_ ScanEvent)` `:217`, `adopt(tree:overlay:cleanup:)` `:241` (→ `.ready`, summary via `applyClassified` → `refreshSummary` `:268,:289,:629`), `windowDidOpen()` `:99` (only loads the summary), `cleanup.category` (`CleanupState.swift:24`).
- `StorageSummary` `Sources/MonitorModel/Storage/Clean.swift:126` (`root`, `scanDate`, `reclaimableBytes?`, `provenance`, `trashBytes?`); `SizeProvenance` `Cleanup.swift:24` (`.exact/.estimate/.unavailable`); `ScanRoot.allowsCleanup` `StorageScan.swift:16`.
- Mocks: `MockStorageState.Kind` `Sources/MonitorMocks/MockStorageState.swift:8` (`empty, scanning, map, cleanup, noFDA`), `make(_:referenceDate:)` `:27`, `home = "/Users/demo"` `:10`; `.scanning` tree finalized at `referenceDate` (`:34-36`), `.map/.cleanup/.noFDA` scanDate = reference − 2 h (`:44`). `MockDataProvider.storageActions(log:state:)` `Sources/MonitorMocks/MockDataProvider.swift:274` (fields are `var`: replace `scan` for the scanning entry). `MockDataProvider.referenceDate` (`ScreenCatalog.swift:67` uses it).
- Catalog: `ScreenCatalog.entries` `Sources/MonitorScreens/Shell/ScreenCatalog.swift:37-54` (pages auto-registered `:43-45`), `context(for:page:ticks:)` `:60-68`, `dashboard(_:scenario:)` `:76-81`, `dashboardSize` `:32`; `ShellStyle.dashboardMinSize` 1100×720 `Shell/ShellStyle.swift:45`.
- ⚠ W3b: `ShellContext` gains `storage: StorageModel` + `storageActions` (defaults) (`Shell/ShellEnvironment.swift:30` init, modifier `:84-95` injects `.environment(context.storage)` and `\.storageActions`); `TelltaleRuntime.storage`; `AppEnvironment.context()` passes them; `DashboardWindowController.show` calls `storage.windowDidOpen()`.
- Sidebar: `Sidebar.value(for:live:units:)` `Shell/Sidebar.swift:52`, `.disk, .storage` branch `:69-73`, call site `:26`; callers in tests `Tests/MonitorScreensTests/ShellConfirmDialogTests.swift:156-203` (keep compiling: new param defaulted).
- Popover: `FlyoutView` `Popover/FlyoutView.swift:17` (body `:37-63`, optional-environment precedent `@Environment(FlyoutPointer.self) … : FlyoutPointer?` `:23`); App hosts it with the full context (`App/Sources/Popover/FlyoutPanelController.swift:180`). `PopoverActions` `Popover/PopoverModel.swift:205-213`. `AppCommands.openDashboard` `Sources/MonitorModel/Services/AppCommands.swift:5`; the App's `openDashboard` closes the popover (`App/Sources/AppDelegate.swift:219-222`), which dismisses the flyout (`App/Sources/Popover/PopoverPanelController.swift:138-142`). Recording commands in tests `Tests/MonitorScreensTests/PopoverTests.swift:124`.
- Launch: `LaunchOptions.parse` `Shell/LaunchOptions.swift:46-85`; `TelltaleRuntime.make(mode:…)` `Sources/MonitorRuntime/TelltaleRuntime.swift:44`, mock branch `:50-51`; `MockPipeline.init(scenario:)` `Sources/MonitorRuntime/MockPipeline.swift:21-25`; App `App/Sources/Composition/AppEnvironment.swift:38` (mode), `:49` (`make`).
- Formatting: `TTFormat.storage(_:style:)` `Sources/MonitorUIKit/Format/TTFormat.swift:112` (`.headline` = DESIGN §5.3); `ShellFormat.freeSpace` `Shell/ShellFormat.swift:11`.

## Spec decisions fixed here

- **"≈" rule** (DESIGN §3.17): prefix "≈" when provenance ≠ `.exact`; `.unavailable` bytes → "—". Tooltip text constant `StorageFormat.estimateTooltip` = "Estimate. Files that share storage with clones may free more when deleted together."
- **Relative time** (DESIGN §5.8 last row): `Scanned just now` (< 60 s, incl. future dates), `Scanned {n} min ago`, `Scanned {n} h ago`, `Scanned {n} d ago` (largest whole unit, no plurals), ≥ 7 d → `Scanned 24 Sep` (`d MMM`, locale from the caller). Pure function of `(date, now, locale, timeZone)`; never reads the clock.
- **Sidebar Storage** (DESIGN §3.0): summary present, `root` is `.home`, `reclaimableBytes != nil` → `"{≈}{bytes} reclaimable"` (`TTFormat.storage(…, .capacity)` like free space, "≈" per rule); otherwise the existing free-space value. Disk row unchanged.
- **Flyout link** (DESIGN §3.1 `:633`): **Disk flyout only** (plan §4 W4c said "row model `PopoverModel.swift:82-89`" — DESIGN wins: the Disk row click keeps opening Disk). Text "Free up space…", or "Free up {≈}{X}…" with the same summary condition and `reclaimableBytes > 0`. Click → `commands.openDashboard(.storage)`.
- **Summary at launch**: the popover is usually opened before the dashboard; if merged W3b loads the summary only in `DashboardWindowController.show`, add a launch-time `Task { await runtime.storage.windowDidOpen() }` in `AppEnvironment` (it only reads `storage-summary.json`, `StorageModel.swift:99-104`). Note what you found in the progress file.

## Tasks (commit per task; prefix `feat(storage-ui):`)

- [ ] **T0 Verify ⚠ W3b** items + the orchestrator prerequisite; record final signatures (file:line) under "Interface deltas". Accept: filled before code.
- [ ] **T1 `StorageFormat.swift`** (`enum StorageFormat`, `public` where W4a/W4b/W4c need it): `bytes(_ b: UInt64?, provenance: SizeProvenance, style: TTFormat.StorageStyle = .headline) -> String`, `estimateTooltip`, `scannedAgo(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String`, `selection(bytes:provenance:count:) -> String` (`Selected ≈14.2 GB · 37 items`, `1 item` singular). Same file: `public enum StorageMode: Hashable, Sendable { case spaceMap, cleanup }` and `extension EnvironmentValues { @Entry var storageInitialMode: StorageMode = .spaceMap }` (pages are built from `init()` by `DashboardRoot`, so the catalog can only pick the mode through the environment). `CleanupView.swift` stub (W4a references both types; W4b replaces them): `struct CleanupView: View { let compact: Bool; var body: some View { TTEmptyState(.empty("Cleanup")) } }` and `struct CleanToastHost: View { var body: some View { EmptyView() } }`. Accept: `StorageFormatTests` green.
- [ ] **T2 Catalog storage entries** in `ScreenCatalog.swift`: `dashboard(_:scenario:size:storage:)` (size default `dashboardSize`, storage default `nil` = empty model); `context(for:page:ticks:storage:)` passes a `StorageModel` into `ShellContext` (⚠ W3b field). Builder `static func storageModel(_ kind: MockStorageState.Kind) -> StorageModel`: `state = .make(kind)`, `actions = provider.storageActions(log: ActionLog(), state: state)`, `StorageModel(actions:, home: MockStorageState.home, now: { MockDataProvider.referenceDate })`, then per kind — `empty`: seed FDA true; `scanning`: `actions.scan = { _, _ in AsyncStream { _ in } }` (never yields, so nothing changes after build), `startScan()`, `apply(.progress(state.progress!))`, `apply(.partial(state.tree!))`; `map`: `adopt` (mode Space Map, focus root); `cleanup`: `adopt` + `.environment(\.storageInitialMode, .cleanup)` on the `DashboardRoot`; `noFDA`: `adopt` + seed FDA false. Entries (sizes `dashboardSize` 1280×860 / `ShellStyle.dashboardMinSize` 1100×720): `storage` stays the auto entry but its default model is **empty** (seeded FDA true), `storage-1100`, `storage-scanning`, `storage-scanning-1100`, `storage-map`, `storage-map-1100`, `storage-cleanup`, `storage-cleanup-1100`, `storage-nofda`, `storage-nofda-1100`. Accept: `scripts/render.sh storage-map calm` and `storage-scanning-1100 calm` produce PNGs (placeholder page is fine now); Read them; `ShellScreenCatalogTests` green (it builds every entry × every scenario, `ShellCompositionTests.swift:274-281`). **→ P0 hand-off.**
- [ ] **T3 Sidebar**: `Sidebar.value(for:live:units:storage: StorageSummary? = nil)`; `Sidebar` reads `@Environment(StorageModel.self) private var storage: StorageModel?` (optional: hosts without a model keep working) and passes `storage?.summary`. Accept: test below; `shell-sidebar-calm` unchanged (context summary nil) — if it changes, find out why before re-recording.
- [ ] **T4 Flyout link**: `FlyoutView` appends the link for `.disk` (separator 1 pt, 4 vertical margin, row 26, padding 10, `body12` `accent`, hover `fillHover`); text from a pure `FlyoutModel.storageLink(summary:) -> String`; action via `PopoverActions.openStorage()` → `commands.openDashboard(.storage)` (add the method next to `openHistory` `:213`). Accept: tests below; new golden `flyout-disk-calm` (Read it); `popover-*` goldens unchanged (the Disk row is untouched) — any diff = bug, investigate.
- [ ] **T5 `--mock-storage <empty|scanning|map|cleanup|noFDA>`** (+ `TELLTALE_MOCK_STORAGE`, passed through by `scripts/run.sh:51-53`): `LaunchOptions.mockStorage: MockStorageState.Kind?` (unknown → `.map`), doc line in the header comment; `TelltaleRuntime.make(…, mockStorage: MockStorageState.Kind = .map)` → `MockPipeline(scenario:storage:)` → `provider.storageActions(log:state: .make(kind))`; `AppEnvironment` passes `options.mockStorage ?? .map`. Ignored in live mode. Accept: parse test; `scripts/build.sh` → `BUILD SUCCEEDED`; `scripts/run.sh --mock calm --mock-storage noFDA --open-dashboard storage` launches (page may still be the placeholder — quote the run.sh line).
- [ ] **T6 Summary at launch** (only if T0 found it missing): `AppEnvironment` launch task. Accept: progress-file note + build.

## Tests (each names its bug)

- `StorageFormatTests` (new, one parametrized test per function): `bytes` exact/estimate/unavailable/nil → "12 GB" / "≈12 GB" / "—" / "—" — bug: estimate shown as exact. `scannedAgo` table: 0 s, 59 s, 60 s, 59 min, 60 min, 23 h 59 min, 24 h, 6 d 23 h, 7 d, future date → exact strings — bug: off-by-one unit boundaries, "1 hours", wall-clock leak. `selection` 1 vs 2 items.
- `ShellSidebarValueTests` (+1 parametrized): home summary exact / estimate / `reclaimableBytes` nil / non-home root / nil summary → reclaimable vs free-space strings — bug: stale or wrong sidebar value, other roots shown as reclaimable.
- `PopoverTests` (+1): `ops.openStorage()` records `open storage` (not `disk`) — bug: link opens Disk. `FlyoutModel.storageLink` table: nil summary / zero bytes / estimate → exact strings (put it in the same parametrized test or in `FlyoutTests`, not both).
- `ShellLaunchOptionsTests` (+1 table row set): `--mock-storage noFDA`, missing value, unknown value, env var — bug: option silently ignored.
- Snapshot tests: **1 new** golden (`flyout-disk-calm`). Re-recorded goldens: expected none; list any in the progress file with the reason.
- Break-check (quote red, revert): drop the `≈` branch in `StorageFormat.bytes` → format test red.

## Gates

- Iterate: `scripts/test.sh StorageFormatTests ShellSidebarValueTests`; record goldens `TELLTALE_RECORD=1 scripts/test.sh FlyoutTests` then Read every new/changed PNG.
- P0 gate: `scripts/ci.sh StorageFormatTests ShellScreenCatalogTests` → `ci.sh: OK`.
- Final: `scripts/ci.sh StorageFormatTests ShellSidebarValueTests ShellLaunchOptionsTests ShellScreenCatalogTests ShellSnapshotTests PopoverTests FlyoutTests` → `ci.sh: OK`; quote it. (Plan's `ShellCompositionTests` is a file, not a suite: `scripts/test.sh` filters by type and fails on zero tests, `scripts/test.sh:35-37`.)

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No `@unchecked` outside `MonitorMocks` (`scripts/ci.sh:63-69`), no `as any`/lint disables/swallowed errors. No `Date()` in views or formatters (inject `now`).
- Comments explain why; match density. No debug prints, TODO stubs (the P0 stubs are the agreed exception, documented as "filled by W4b"), commented-out code.
- Tool output ≤ 100 lines (`tail`/`grep`).
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefix `feat(storage-ui):`; message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W4c.md`: Plan / Done (hashes) / P0 ready / Next / Interface deltas / Goldens changed / Requests / Not verified / Blockers.
- Don't merge; no Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, P0 hash, deltas, not verified.
