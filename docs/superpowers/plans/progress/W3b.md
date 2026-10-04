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

## Review round 1 (Codex: 1 P1, 8 P2, 1 P3; all fixed; rebased on feat/storage 7fb86e3)
- `promptMode: .allow` explicit in the live scan policy; sidecar format needs no change (`ScanCache.saveOverlay` encodes the overlay, log replayed on load).
- P1 cancel: runs are registered at request time in engine state; start (+ publishing the cleaner) happens under the lock `cancelClean` takes; a cancel seen first makes the run refuse (`.cancelled` outcomes, `report.cancelled`). Test `cancelBeforeTheRunStartsRefusesIt` (seam `Environment.beforeCleanRegistration`).
- Run context: each clean/undo/Empty Trash run captures {root, tree, overlay, set, items}; sidecar (`engine.saveOverlay(_:)`, now takes the overlay) and summary go against that scan; engine overlay and pipeline set replaced only while the tree still matches. Summary file never overwritten by an older scan (scanDate guard). Tests: close mid-clean, close/rescan.
- Summary and `adopt` use a projection (hidden nodes incl. trashed ancestors dropped, shrunk keep-parent sizes): local copy of `StorageModel.presented` minus path renames (MonitorLive is not mine). Test `summaryStaysCleanedAfterReclassify`.
- Undo: one `UndoStore` per authorized root (`storage-undo.json` for home, `storage-undo-<hash>.json` otherwise, roots listed in `storage-undo-roots.json`); `undo(record)` uses the store that holds the id. Test with an external root.
- `loadCached` advances the generation (and cancels a running scan); `startSizing` and the resolved set refresh running apps right before publication; first classification is emitted before owner lookups; FDA banner = confirmed grant only; quit during launch: deleter and `aborted` flag published before the sweep (sweep skipped when aborted).
- Unmount test: no sleep (scanner ends the stream at once).
- Break-once (red, reverted): cancel flag check removed; `loadCached` generation bump removed; sidecar write + `replaceOverlay` version guard removed.

## Requests
None.

## Not verified
- Live run: `run.sh --open-dashboard storage` launched and stopped; storage log lines (sweep) not seen in `log show`; window-close path only compiled.
- Real FDA, real eject, real Trash/undo, real NSWorkspace `appPaths` casing for normalized (lowercase) bundle IDs.
- `StorageActionsLive.decorate` reveal / FDA URL (not clicked); promptMode (W2a) not adopted yet.
- Summary after a cached load only written when the follow-up `reclassify` runs (W3a calls it).

## Blockers
None.
