# W3b progress (engine, runtime composition, StorageActionsLive, app wiring)

Branch `ws/storage-w3b` (from `feat/storage` d32c471). Paths under `MonitorCore/`.

## Plan / Done
T0 verify APIs, T1 StorageEngine, T2 StoragePipeline + runtime, T3 settings/StorageActionsLive/ShellContext, T4 app wiring: all done (see `git log`).
Gate: `scripts/build.sh` BUILD SUCCEEDED; `scripts/ci.sh StorageRuntimeTests ShellStorageTests RuntimeTests StorageModelTests StorageMockTests ShellSnapshotTests` -> `ci.sh: OK`.
Break-checks (red, reverted): generation checks removed (isLive/isLiveScan/emit) -> `releaseDropsLateClassification` red; runningApp pass dropped -> `runningOwnerIsFlaggedIn...` 3 issues.

## Interface deltas
- `Sources/MonitorDiskTools/Engine/StorageEngine.swift`: `StorageEngine(Environment)`, `Environment.live(home:dataDirectory:platform:)` (fields are vars; tests override). `scan(root:options:)`, `cancelScan()`, `loadCached`, `reclassify`, `release()`, `policy()`, `checkInUse`, `hasFullDiskAccess`, `availableRoots`, `clean`, `emptyTrash`, `cancelClean`, `undo`, `abortDeletes()`, `current()`, `replaceOverlay(_:)`, `saveOverlay()`.
- `Sources/MonitorRuntime/StoragePipeline.swift` (internal): `actions`, `shutdown()`; summary at `dataDirectory/storage-summary.json`.
- `RuntimePipeline.storageActions`; `TelltaleRuntime.storage: StorageModel`, `.storageActions`; `make(..., storagePlatform:, decorateStorageActions:)`.
- `StorageActionsLive.platform(center:)`, `.decorate(_:settings:)` (Shell).
- `SettingsStore`: `storageIgnoredPaths: Set<String>`, `storageLargeThreshold`, `storageOldThreshold`, `classifyOptions(now:)`; keys `storage.*`.
- `ShellContext(storage:storageActions:)`; environment: `.environment(StorageModel)`, `\.storageActions`.

## Deviations from brief
- Scan cache tree saved right at `.finished` (before classify); no fresh overlay sidecar written (`ScanCache.save` drops the old one, `load` returns a fresh overlay when none).
- Classification/`.classified` only for `.home` roots; `loadCached` for other roots returns an empty resolved set.
- `.classified` emitted twice per scan before the sizing pass (pre- and post-resolve) plus the final one.
- Overlay tee applies one batch per run on `.finished` (not per event); sidecar + summary written before the consumer sees `.finished`.
- Banner FDA uses `FullDiskAccessProbe.check` (inconclusive = granted); the scan policy treats inconclusive as not granted.
- `runningApp` compared lowercased on both sides.
- `willUnmount` test waits 200 ms for the scanner's watcher (no observable signal); can only fail red.

## Requests
None.

## Not verified
- Live run: `run.sh --open-dashboard storage` launched and stopped; storage log lines (sweep) not seen in `log show`; window-close path only compiled.
- Real FDA, real eject, real Trash/undo, real NSWorkspace `appPaths` casing for normalized (lowercase) bundle IDs.
- `StorageActionsLive.decorate` reveal / FDA URL (not clicked); promptMode (W2a) not adopted yet.
- Summary after a cached load only written when the follow-up `reclassify` runs (W3a calls it).

## Blockers
None.
