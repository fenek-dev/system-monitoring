# W3b brief — engine, runtime composition, StorageActionsLive, app wiring

Self-contained. Source of truth order: **merged code (W1, W2a–d, W3a, W3c) > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §0, §3, §4 W3b, §6; spec `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` §3.1, §3.3–3.5, §3.8, §6.5, §6.6, §7). This stream gets an `xhigh` review: correctness over speed.

**Starts only after W2a, W2b, W2c, W2d, W3a and W3c are merged into `feat/storage`.** W2 APIs below were taken from in-progress branches/briefs — every "⚠ verify" line must be checked against merged code first; differences go into your progress file (code wins).

Paths are under `MonitorCore/` unless they start with `docs/`, `scripts/`, `App/`.

## Goal

Compose the live storage backend and wire it into the app: `StorageEngine` (DiskTools) runs scan → classify → resolve → private sizes → cache; `StoragePipeline` (Runtime) turns it into `StorageActions`, keeps the persisted overlay + summary file, sets `runningApp`; `TelltaleRuntime` exposes `storage: StorageModel` + `storageActions`; `StorageActionsLive` (Screens) supplies AppKit/Settings pieces (`StoragePlatform`, reveal, FDA pane, ignore/unignore); app wiring incl. window close → `storage.windowDidClose()`.

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w3b`, branch `ws/storage-w3b` (orchestrator creates it from `feat/storage` after the merges above). Work, test, commit only there; rebase before handing back. **Do not merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (add `.codegraph/` to `$(git rev-parse --git-common-dir)/info/exclude` if it shows up); else `codegraph sync -q`. `codegraph explore "<symbols>"` before grep.

## Prerequisite (orchestrator, before start)

`Package.swift` is W1-owned. `MonitorRuntimeTests` deps are `MonitorRuntime, MonitorModel, MonitorMocks, MonitorStore, MonitorEngine` (`Package.swift:127-130`) — no `MonitorDiskTools`/`MonitorLive`, which `StorageRuntimeTests` need (engine fakes, `StorageModel`). Orchestrator adds both before you start; if missing, record under Requests and stop on that test file only.

## Ownership

Own: `Sources/MonitorRuntime/{TelltaleRuntime,LivePipeline,StoragePipeline}.swift`, `Sources/MonitorDiskTools/Engine/**`, `Sources/MonitorScreens/Shell/{ShellEnvironment,StorageActionsLive,SettingsStore}.swift`, `Sources/MonitorUIKit/Environment/EnvironmentValues+Telltale.swift`, `App/Sources/Composition/AppEnvironment.swift`, `App/Sources/Dashboard/DashboardWindowController.swift`, `Tests/MonitorRuntimeTests/Storage*`, `Tests/MonitorScreensTests/ShellStorage*`, `docs/superpowers/plans/progress/W3b.md`.

Must not touch: `Sources/MonitorModel/**`, `Package.swift`, `Sources/MonitorDiskTools/{DiskTools.swift,Support,Scan,Cache,Classify,Clean}/**`, `Sources/MonitorLive/**`, `Sources/MonitorMocks/**`, `Sources/MonitorRuntime/MockPipeline.swift` (W3c), `ScreenCatalog.swift`, `Sidebar.swift`, pages. Need a change there → local extension in your files + Requests.

## APIs consumed

W1 (verified at `64c8bf1`, `Sources/MonitorModel/Storage/`):
- `StorageActions` `StorageServices.swift:28` (fields `:29-52`, `.noop` `:99`), `StoragePlatform` `:5` (`runningBundleIDs` `:7`, `appPaths` `:9`, `willUnmount` `:11`, `.none` `:23`).
- `CleanupItem` `Cleanup.swift:54` (`runningApp` `:75`, `owner` `:74`), `CleanupSet` `:122`, `ClassifyOptions` `:143` (defaults `:152-155`, init `:157`), `ScanEvent` `StorageScan.swift:41`, `StorageSummary` `Clean.swift:122` (Codable), `CleanReport.undo` `:72`, `StorageTreeOverlay` `StorageTreeOverlay.swift:37` (`rebased(onto:)` `:99`), `StoragePolicy` `StoragePolicy.swift:6`.
- `DiskTools.log` `Sources/MonitorDiskTools/DiskTools.swift:7`; `TrustedRoot`/`FileDescriptor` in `Support/`.

W3a (⚠ verify `docs/superpowers/plans/progress/W3a.md` interface deltas): `StorageModel(actions:home:now:)`, `windowDidOpen()`, `windowDidClose()`; `StorageCleanMath.apply(_:item:to:tree:)`, `.applyRestore(itemID:finalPath:item:to:tree:)`, `.reclaimable(set:tree:overlay:)` — the only overlay-mutation and reclaimable code; never re-implement.

W3c (⚠ verify `progress/W3c.md`): `MockPipeline.storageActions: StorageActions` (`Sources/MonitorRuntime/MockPipeline.swift`).

W2a scan (⚠ verify; branch `ws/storage-w2a` @ `63e9fe4`, brief `briefs/W2a.md`):
- `Scanner(lister:threads:home:)` `Scan/Scanner.swift:17`, `defaultThreadCount()` `:24`, `scan(root:willUnmount:) -> AsyncStream<ScanEvent>` `:36` (plan §3.3 said `unmount:`), `cancel()` `:76`. `BulkLister`, `InMemoryLister` (tests).
- `ScanCache(directory:)` `.save(_ tree)`, `.saveOverlay(_:)`, `.load(root:volumeUUID:) -> (StorageTree, StorageTreeOverlay)?` (brief T5; uncommitted at brief time). Volume UUID for a root: use W2a's helper if one exists, else `URLResourceValues.volumeUUIDString` (Foundation).
- `PrivateSizer` (brief T7: items + tree → updated items + `linkGroupSizes`, cancellable), `FullDiskAccessProbe.check(home:) -> Bool`, `ScanRoots.available() -> [ScanRoot]`.

W2b classify (⚠ verify; branch `ws/storage-w2b` @ `227b9b1`):
- `InstalledAppSet.build(home:mdfind:)` `Classify/InstalledAppSet.swift:73`; `Classifier(home:dataDirectories:git:devTools:isUbiquitous:)` `Classify/Classifier.swift:25`, `classify(tree:installed:lastUsed:options:) -> ClassifyResult` `:34`, `resolve(_:found:) -> CleanupSet` `:47`, `ClassifyResult { set, unresolvedBundleIDs }` `:6`. Classifier emits `runningApp: false` (`:90`) and `parentID` nil — `runningApp` is yours (below), grouping is W3a's.
- `SpotlightLastUsed.query(root:minBytes:) -> [String: Date]` (uncommitted at brief time).

W2c clean (⚠ verify; no code at brief time — API from `briefs/W2c.md` "API to implement"):
- `Cleaner(context: CleanContext)` `.clean(_ items:, tree:, overlay:) -> AsyncStream<CleanEvent>`, `.cancel()`, `.emptyTrash()`; `CleanContext { home, permittedRoot, stagingDir, dataDirectories, trash, deleter, evictor, simctl, log }`; `Denylist.build(home:scanRoot:dataDirectories:)` `.policy(for:)`; `Staging(dir:).sweep() -> SweepReport`; `UndoStore(file:)` `.append/.prune(now:)/.restore(_:) -> AsyncStream<CleanEvent>`; `InUseChecker(processes:).inUse(_:) -> Set<Int32>`; `DeleteWorker.slimSupported`. Check whether `Cleaner` appends the undo record itself; if not, the engine appends `report.undo` on `.finished`.

W2d: nothing consumed (UIKit); `EnvironmentValues+Telltale.swift` is yours this wave.

Existing code (verified at `64c8bf1`):
- `TelltaleRuntime` `Sources/MonitorRuntime/TelltaleRuntime.swift:34`, `RuntimePipeline` `:11-25`, `make(mode:dataDirectory:disabledSensors:crashSensor:canarySuite:)` `:44-53`, `shutdown` `:76`. `LivePipeline` `LivePipeline.swift:44` (convenience init), log precedent `:41`.
- `ShellContext` `Sources/MonitorScreens/Shell/ShellEnvironment.swift:10-45` (init `:30`), modifier `:78-106` (inject at `:84-95`). `ScreenCatalog.context` `ScreenCatalog.swift:59-67` must compile unchanged (new params defaulted).
- `@Entry` list `Sources/MonitorUIKit/Environment/EnvironmentValues+Telltale.swift:6-13`.
- `SettingsStore` keys `Sources/MonitorScreens/Shell/SettingsStore.swift:18-28`, field pattern `:99-100`, load in init `:103-112`; `InMemoryDefaults` `Shell/InMemoryDefaults.swift:10`.
- `ProcessActionsLive` `Sources/MonitorScreens/Shell/ProcessActionsLive.swift:19` (`make` pattern, AppKit allowed here).
- App: `AppEnvironment` `App/Sources/Composition/AppEnvironment.swift` — `runtime` `:15`, `dataDirectory` `:34`, `settings` `:36`, `TelltaleRuntime.make` `:49`, `context()` `:69-72`, data dirs `:76` (`dev.warden`) / legacy `:80`; `DashboardWindowController` `App/Sources/Dashboard/DashboardWindowController.swift` — `env` `:11`, `show` `:25`, `windowWillClose` `:93`.

## Design (fixed by the orchestrator)

- **`Engine/StorageEngine.swift`** (`final class … : Sendable`, state in `Mutex`; no AppKit; injected dependencies struct with live defaults and test fakes: lister/scanner factory, classifier, installed-apps builder, Spotlight query, private sizer, cleaner, in-use checker, `StoragePlatform`, clock). Serial `.utility` queue for classify / resolve / private sizes / Spotlight / installed apps (spec §3.5). Pipeline per scan: `scanner.scan(root:willUnmount: platform.willUnmount())` → forward `.progress/.partial/.failed` → on `.finished`: emit it, classify → `.classified` → resolve via `platform.appPaths` for `unresolvedBundleIDs` → `.classified` → private sizes → `.classified(final)` → `ScanCache.save(tree)` + fresh overlay sidecar (success only; never for partial/cancelled/failed).
- **Generation counter**: bumped by `release()` and by each new scan; every async step captures it and drops its result (no emit, no state stored) if it changed. `release()` (window close) drops tree, overlay, set, installed set, Spotlight map; a running clean keeps its own captured refs and drains (spec §3.4).
- **`runningApp`** (spec §6.5 badge): before every emitted/returned `CleanupSet` (scan `.classified`, `loadCached`, `reclassify`), `item.runningApp = item.owner.map { running.contains($0.bundleID) } ?? false` with `running = await platform.runningBundleIDs()`.
- **`loadCached(root, options)`**: `ScanCache.load` → classify + resolve → return `(tree, overlay, set)` (map available at once). Private sizes continue on the engine queue; `reclassify(options)` awaits that pass for the current tree, then classifies with the new options reusing private sizes by path. (W3a calls `reclassify` once after a cached load when `!set.privateSizesFinal`.)
- **Cleaning**: `CleanContext(stagingDir: dataDirectory/staging, permittedRoot: home for Cleanup / scan root for Space Map trash, dataDirectories: [dataDirectory])`. Cross-volume staging = skip `.stagingOtherVolume` (Cleaner's rule), no fallback — do not add one. Launch (off-main, before the first clean is allowed): `Staging.sweep`, `UndoStore.prune(now:)`, SLIM/RESOLVE probes; log `SweepReport`.
- **`StoragePipeline.swift`** (`@MainActor final class`, MonitorRuntime): owns the engine, builds `StorageActions`. Tees clean/undo/emptyTrash streams: applies each event to its own overlay copy via `StorageCleanMath`, passes events through; on `.finished` → `ScanCache.saveOverlay` and writes `dataDirectory/storage-summary.json` (home root only: `StorageCleanMath.reclaimable` + provenance, `trashBytes`, `scanDate`; atomic write). Also writes the summary after the final `.classified` of a home scan and after a cached load's final pass. `loadSummary` reads it (missing/corrupt → nil, logged). `release` → engine `release()`. `shutdown()` → delete-worker cancel (W2c: only at app quit).
- **Runtime**: `RuntimePipeline` += `var storageActions: StorageActions { get }` (Live → `StoragePipeline`; Mock → W3c's property). `TelltaleRuntime.make(…, storagePlatform: StoragePlatform = .none, decorateStorageActions: @MainActor (StorageActions) -> StorageActions = { $0 })`: decorator applied in `.live` only; `storage = StorageModel(actions: decorated)`; exposes `storage`, `storageActions`. (ignore/reveal live in Screens; the model must be built with the final actions, so the runtime takes a decorator.)
- **`StorageActionsLive`** (`enum`, AppKit): `platform() -> StoragePlatform` — `NSWorkspace.shared.runningApplications` bundle IDs; `urlsForApplications(withBundleIdentifier:)` paths; `willUnmount` = `AsyncStream` over `NSWorkspace.shared.notificationCenter` `willUnmountNotification` (`userInfo["NSDevicePath"]`, ⚠ verify key in AppKit headers), observer removed on termination. `decorate(_ base: StorageActions, settings: SettingsStore) -> StorageActions`: `revealInFinder` (`activateFileViewerSelecting`), `openFDASettings` (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, ⚠ verify), `ignore`/`unignore` → `settings`.
- **`SettingsStore`**: `storage.ignoredPaths` (`[String]` → `Set<String>`), `storage.largeThreshold`, `storage.oldThreshold` (UInt64 bytes; invalid → `ClassifyOptions` defaults) following `:18-28`/`:99-112`; plus `func classifyOptions(now: Date) -> ClassifyOptions` for W4.
- **Shell**: `ShellContext` += `storage: StorageModel = StorageModel(actions: .noop)`, `storageActions: StorageActions = .noop` (init `:30`); modifier injects `.environment(context.storage)` and `.environment(\.storageActions, …)`; `@Entry var storageActions: StorageActions = .noop` in `EnvironmentValues+Telltale.swift`.
- **App**: `AppEnvironment` passes `storagePlatform: StorageActionsLive.platform()`, `decorateStorageActions: { StorageActionsLive.decorate($0, settings: settings) }` at `:49`; `context()` passes `runtime.storage`/`runtime.storageActions`. `DashboardWindowController.show` (new window) → `Task { await env.runtime.storage.windowDidOpen() }`; `windowWillClose` (`:93`) → `env.runtime.storage.windowDidClose()`.

## Tasks (commit per task, prefix `feat(storage-runtime):`)

- [ ] **T0** Verify every ⚠ API against merged code; record deltas. Accept: progress file "Interface deltas" filled before code.
- [ ] **T1 `StorageEngine`**: pipeline, generation, release, runningApp, loadCached/reclassify, launch tasks, clean/undo/emptyTrash/checkInUse/policy/FDA/roots. Accept: engine tests green.
- [ ] **T2 `StoragePipeline` + `TelltaleRuntime`/`LivePipeline` composition** (overlay tee, sidecar, summary file). Accept: runtime tests green; `RuntimeTests` still green.
- [ ] **T3 `SettingsStore` keys, `StorageActionsLive`, `ShellContext`/`@Entry`.** Accept: `ShellStorageTests` green; `ScreenCatalog.swift` unchanged and compiles.
- [ ] **T4 App wiring.** Accept: `scripts/build.sh` → `BUILD SUCCEEDED`; `scripts/run.sh --open-dashboard storage` launches (placeholder page), close window → log line from `windowDidClose`; quote both. Not verified items listed.

## Tests (each names its bug; real temp dirs, injected home/permitted root/data dir; no sleeps — order via streams and gated fakes)

- `StorageRuntimeTests` (temp home = permitted root): fixture `Library/Caches/com.example.storage-fixture` (id matches no exclusion) appears as a checked User Caches item **before** cleaning (assert first) → `clean` → dir gone, `freedBytes > 0`, overlay sidecar reloads with the node removed, summary file reclaimable == `StorageCleanMath.reclaimable` of the post-clean state — bug: wiring drops events / fixture silently excluded / stale sidebar.
- Cancelled scan (`cancelScan` mid-stream via gated `InMemoryLister`) → `.failed(.cancelled)`, no cache file — bug: partial result cached.
- Release race: classify fake gated by the test; `release()` before it completes → no `.classified` delivered, engine holds no tree (`loadCached` without cache → nil) — bug: late results resurrect a released tree.
- `runningApp`: `platform.runningBundleIDs` stub returns the fixture owner's id → item `runningApp == true` in scan `.classified`, `loadCached` and `reclassify` results — bug: running app's caches pre-checked.
- `ShellStorageTests`: `ignore(path)` persists in `InMemoryDefaults`, `settings.classifyOptions(now:)` contains it, `unignore` clears it; invalid threshold value → default — bug: ignore lost on relaunch / unignore impossible. `StorageActionsLive.platform().willUnmount()` yields the path from a posted `willUnmountNotification` — bug: eject never cancels a volume scan.
- Break-checks (quote red then green): skip the generation check → release-race test red; drop the runningApp pass → runningApp test red. Revert.

## Gates

- Iterate: `scripts/test.sh StorageRuntimeTests` etc.
- Merge gate: `scripts/ci.sh StorageRuntimeTests ShellStorageTests RuntimeTests StorageModelTests StorageMockTests` → `ci.sh: OK`; quote it. `scripts/build.sh` for the app.

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No `@unchecked` (`scripts/ci.sh:63-69`), no `as any`/lint disables, no swallowed errors (failed summary/sidecar writes → logged `.error` with path; per-item failures stay in `CleanReport`). Locks: `Mutex`/`OSAllocatedUnfairLock`. No AppKit in `MonitorDiskTools`/`MonitorRuntime`; no `import MonitorDiskTools` in Live/Screens/UIKit/App (`scripts/ci.sh:50-61`).
- Logging `Logger(subsystem: "dev.telltale", category: "storage")` (`DiskTools.log`).
- Comments explain why. No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines: pipe through `tail`/`grep`.
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefix `feat(storage-runtime):`; message ends with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W3b.md`: Plan / Done (hashes) / Next / Interface deltas (final signatures, file:line) / Requests / Not verified (real FDA, real eject, real Trash) / Blockers.
- Don't merge; don't run Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, interface deltas, not verified.
