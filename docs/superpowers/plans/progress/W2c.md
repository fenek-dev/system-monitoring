# W2c — cleaner progress

Branch `ws/storage-w2c` (from `feat/storage` @ 64c8bf1). All paths under `MonitorCore/Sources/MonitorDiskTools/Clean/`.

## Plan
T1 Denylist, T2 policy checks, T3 Staging journal, T4 keep-parent, T5 DeleteWorker, T6 sweep, T7 trash/evict/simctl/Empty Trash, T8 Cleaner stream, T9 UndoStore, T10 InUse. Tests: Staging, Denylist, Cleaner, Undo, InUse.

## Done
- All tasks T1-T10 (commits: source `2982d62`, then fix + tests commit, see `git log`).
- Break-checks: post-rename identity check dropped -> StagingTests 7 issues (replacedAfterScan, rollbackCollision red); "inside protected" check dropped -> Denylist/Cleaner tests red (Mail data was deleted in `protectedTargetsAreDeniedFromLiveState`); both reverted.
- Gate: `scripts/ci.sh StagingTests DenylistTests CleanerTests UndoTests InUseTests` -> `ci.sh: OK`.

## Interface deltas (final signatures)
- `CleanContext(home:permittedRoot:stagingDir:dataDirectories:trash:deleter:evictor:simctl:inUse: = nil, log: = DiskTools.log)` Cleaner.swift:7. `inUse` is an addition: set -> in-use items skipped `.inUse`.
- `Cleaner(context:)`; `clean(_:tree:overlay:) -> AsyncStream<CleanEvent>`; `cancel()`; `emptyTrash()`; `abortDeletes()` (new: `removefile_cancel` of in-flight deletes, app quit only). Single flight per Cleaner.
- Protocols (public): `TrashMover.trash(path:) throws(TrashError) -> String` (TrashMover.swift), `Evictor.evict(path:) throws(EvictError)`, `SimctlRunner.deleteUnavailable() -> SimctlResult`, `Deleter.delete(_ DeleteTarget, clearImmutable:) -> DeleteOutcome` + `cancelInFlight()`. Live: `SystemTrashMover`, `UbiquitousEvictor`, `ProcessSimctlRunner(timeout: 60)`, `DeleteWorker(slim:)`, `DeleteWorker.slimSupported(scratchIn:)` (probe; use a dir you own, e.g. staging).
- `Denylist.build(home:scanRoot:dataDirectories:)`, `.check(chain:)`, `.check(root:target:)`, `.policy(for:)`.
- `Staging(dir:deleter:)`, `.sweep() -> SweepReport {deleted, deleteFailures, restored, leftovers, orphanSidecars, error}`. Call at launch.
- `UndoStore(file:permittedRoot:)` (permittedRoot is the extra arg): `append(_:) throws`, `prune(now:) throws`, `records() throws`, `restore(_:) -> AsyncStream<CleanEvent>` (`.restored` per entry, failures as `report.outcomes[].skip`, one `.finished`; restored entries are removed from the stored record).
- `InUseChecker(processes:)`: `inUse(_:) -> Set<Int32>`, `check(_:) -> InUseReport {inUse, unknownHolders}`; `ProcessPathSource.snapshot() -> HeldPaths`; live = `LiveProcessPathSource`.
- Events: `.item` is emitted at detach time. Delete-failure `partial` is only in `.finished` report outcomes. `report.cancelled` = at least one item/child skipped because of cancel. Cancelled items get `.item(skip: .cancelled)`.
- Outcome semantics: remove -> `removedNodes` = [node] (W3a: `.deleted`); trash -> removedNodes [node], `trashedTo`, bytes in `trashedBytes` (W3a: `.trashed`); evict -> bytes in `evictedBytes`, no removedNodes; simctl -> bytes credited as freed, no node/identity needed, never touches the path; `.none` -> `.notPermitted`. Vanished: remove = success 0 B with removedNodes [node]; trash/evict = `.vanished`, no nodes. Trash/evict need `item.identity` (or node identity from tree).
- Empty Trash outcomes use the child index as `itemID`.
- Backpressure: detach waits for one of 4 delete slots, so after `cancel()` at most 4 committed entries remain to drain.

## Notes / deviations
- `removefile` symbols come from the CPrivate shim header (see review round).
- Measured: `REMOVEFILE_RECURSIVE_SLIM` on a plain file fails ENOTDIR; SLIM is used only for directories. SLIM also silently skips unreadable (000) directories (no callback), and returns rc 0 with errno 66; so permission repair is a tree walk of the leftover entry (up to 5 rounds), not "one retry on the failing path".
- Symlink path component: the no-follow `O_DIRECTORY` open yields ENOTDIR (not ELOOP) in the component walk, so the item is skipped `.changedSinceScan` (not `.outsideRoot`); nothing outside is touched.
- keep-parent child bytes: tree size if the child is a node whose tree identity equals the live inode, else live allocated size (`st_blocks*512`, directories walked, hard links once). Children not valid UTF-8 are counted as skipped.
- Empty Trash bytes are the live allocated size of each child.
- `Evictor` lives in TrashMover.swift (no separate file).
- W2b note: simctl item has nodeID nil / identity nil -> handled; Docker `.none` -> `.notPermitted`.
- Denylist anchors/protected are built once per `clean()` (live at that time), not per item.
- Cleaner takes `permittedRoot` as `TrustedRoot` (kernel resolution when the probe passes; `openParent` always walks).

## Codex review round (all 17 accepted, fixed)
- P1-1 every mutation re-runs a fresh `TrustedRoot` + `Denylist.build` + chain check (`Cleaner.authorize`), after the slot wait; keep-parent re-authorizes per child and re-checks the item directory identity. Break-check (cached denylist): 2 tests red.
- P1-2 per-run cancel token (`Run.cancelFlag`); `cancel()` cancels runs active at that moment. Break-check (reset on start): red.
- P1-3 `removefile` now via CPrivate `RemoveFileShim.h` (declarations by hand: `#include <removefile.h>` is not importable from the module; MonitorDiskTools depends on CPrivate, Package.swift edit approved). Cancel, unregister and free share one lock. No deterministic test for the free race; the persistent abort flag is tested (break-check: red).
- P1-4 undo entry only when the landed inode equals the trashed one; otherwise logged, no entry (W3a: item id missing from `report.undo` while `trashedTo` is set means "trashed, not undoable"). Break-check: red.
- P2: undo revalidates source before each rename (seam `UndoStore.beforeRename`); hard-link ledger per run (only for live-measured sizes: keep-parent children without a matching scanned node, Empty Trash; scanned tree sizes keep the model's link rules); ECANCELED/abort stop the retry loop; unlock authorization persisted as `commit/<id>.unlock` and honored by the sweep; `.freed` is deferred until its `.item` was emitted; cancellation in slot wait marks `cancelled`; in-use matching canonicalizes a non-symlink leaf with `realpath` (case); symlink anchors also anchor their own inode; permission repair is limited to the entry's device (`DeleteWorker.repair(dev:)` tested with a wrong device number, no real second device); EPERM counted once per pid at any libproc stage (not unit-tested: needs a foreign-uid process); residual failure line carries removefile's rc/errno (not unit-tested: needs an entry that survives silently).
- P3: case and NFD tests split with `.enabled(if:)` volume probes; keep-parent test uses real inodes with a different scanned size.
- Contract: `CleanItemOutcome.path` (Clean.swift) filled for every Empty Trash outcome.

## Review r2 (final)
- Denylist redesign: identity sets + folded component rules built once per run; per mutation (all paths incl. Empty Trash children, keep-parent children, trash, evict) a fresh TrustedRoot walk, identity check and component-spelling check (`Denylist.check(live:)`). Empty Trash resolves each entry from the home root and requires the same `.Trash` identity as at listing. Perf: 1000 authorizations = ~184 ms (debug), was ~11 s.
- Seams: `CleanTestHooks.beforeSlotWait`, `DeleteWorker(slim:onFailure:)` (callback runs while removefileat is in flight; used for the in-flight abort test).
- CleanItemOutcome.path: one copy (matches feat/storage).

## Requests
- none open.

## Not verified
- macOS 14.x/15.x behavior of RENAME_NOFOLLOW_ANY / SLIM (measured on 26.5 only).
- Real `~/.Trash` via `FileManager.trashItem`, Finder Put Back, real `.Trashes/<uid>` (tests use a fake TrashMover and temp dirs).
- Real `xcrun simctl delete unavailable`, real `evictUbiquitousItem`.
- Case/NFD variant test is skipped silently on case-sensitive volumes (runs here).

## Blockers
None.
