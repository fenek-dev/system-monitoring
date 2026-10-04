# W2c brief — cleaner, guardrails, staging journal, undo, in-use

Self-contained. Source of truth order: **W1 code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §0 threat model, §4 W2c, §6 S1/S2/S4/S5/S6). If a W1 type differs from this brief, the code wins; record the mismatch in your progress file. A Codex review of W1 may land small contract fixes before you start — re-read the cited files. This stream gets an `xhigh` review: correctness over speed.

Paths below are under `MonitorCore/` unless they start with `docs/`, `scripts/`, `App/`.

## Goal

The only code that deletes or moves user files: live denylist with identity chains, remove-mode staging journal (pending → commit) with a ≤ 4-way delete worker, Move to Trash with a persisted undo record, evict, simctl, Empty Trash, launch sweep, in-use check. Everything fd-relative under a `TrustedRoot`. W3b composes it (`Engine/`, not yours).

**Threat model (binding, plan §0):** guard against stale scan data, our own bugs, ordinary concurrent changes (files replaced/moved/re-created between scan and clean), path spelling (case, Unicode normalization, `..`, symlinks, prefix lookalikes). Not against a hostile same-user process. So: identity checks right before each step; small accepted TOCTOU windows where an API takes a URL (comment each one); no privilege separation.

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w2c`, branch `ws/storage-w2c` (created from `feat/storage` by the orchestrator after W1 merged). Work, test, commit only there. Rebase on `feat/storage` before handing back. **Do not merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (if `git status` then lists `.codegraph/`, add it to `$(git rev-parse --git-common-dir)/info/exclude`); else `codegraph sync -q`. Use `codegraph explore "<symbols>"` before grep.

## Ownership

Own: `Sources/MonitorDiskTools/Clean/**` (`Cleaner, Denylist, Staging, DeleteWorker, TrashMover, Evictor, SimctlRunner, UndoStore, InUseChecker, ProcessPathSource`.swift), `Tests/MonitorDiskToolsTests/{Cleaner,Staging,Undo,InUse,Guardrail,Denylist}*`, `docs/superpowers/plans/progress/W2c.md`.

Must not touch: `Sources/MonitorModel/**`, `Sources/MonitorDiskTools/{DiskTools.swift,Support/**,Scan/**,Cache/**,Classify/**,Engine/**}`, `Tests/MonitorDiskToolsTests/Support/**` (W1), `Package.swift`, `scripts/**`, other docs.
Escalation: a needed change in a file you don't own (e.g. a `TrustedRoot` helper) → local extension in `Clean/` (or test helpers in e.g. `CleanerTestSupport.swift`), record under "Requests" in your progress file.

## W1 APIs you consume (verify; code wins)

Model (`Sources/MonitorModel/Storage/`):
- `DenyReason` `Clean.swift:3` (`anchor, protected, outsideRoot, removeOutsideHome, unverifiable`), `SkipReason` `:15`, `CleanItemOutcome` `:29` (init with defaults `:41`), `CleanEvent` `:55` (`.item`, `.freed`, `.restored`, `.finished` exactly once), `CleanReport` `:63`, `UndoRecord` `:87`, `UndoEntry` `:99` (`trashParentPath`, `trashParentIdentity`).
- `CleanupItem` `Cleanup.swift:54` (`path`, `nodeID`, `identity`, `mode`, `keepParent`, `privateBytesExcludingLinks`, `allocBytes`), `DeleteMode` `:11`.
- `StoragePolicy` `StoragePolicy.swift:6` (`treeVersion`, `anchors`, `protected` node sets; `denyReason(trash:in:)` `:23`) — you produce it from the denylist for the UI (advisory; backend always re-checks live).
- `StorageTree` `StorageTree.swift:9`: `lookup(path:)` `:151`, `sortedChildren` `:123`, `name` `:96`, `size` `:114`; `StorageTreeOverlay` `StorageTreeOverlay.swift:31` (`isRemoved(_:in:) throws(StorageOverlayError)` `:146`; throws `.treeMismatch` if the overlay belongs to another tree version — treat as unverifiable, never as "not removed"). Outcomes must let W3a tell deleted from trashed removals (`remove(_:kind: .deleted|.trashed, in:)` `:88`): remove mode → `.deleted`, trash → `.trashed`.
- `FileIdentity` `StorageBasics.swift:51` (Hashable on dev+ino+isDirectory).

DiskTools support (`Sources/MonitorDiskTools/`):
- `DiskTools.log` `DiskTools.swift:7`: one line per detached/trashed/evicted path with bytes and mode (spec §7.4).
- `SafePathError` `Support/FileDescriptor.swift:4` (`.posix(op:errno:)`, `.errno`); `FileDescriptor` `:19` (`~Copyable`; `open(at:_:flags:)` `:32`, `duplicate()` `:45`, `identity()` `:51`, `identity(of:)` `:58` = `fstatat AT_SYMLINK_NOFOLLOW`).
- `RelativePath` `Support/SafePath.swift:6` (`validating` `:9`, `components` `:15`, `confined(_:under:)` `:29` — component compare, never string prefix; `leaf` `:40`).
- `TrustedRoot` `Support/SafePath.swift:49`: `init(path:resolution: .automatic|.componentWalk)` `:68` (test seam `.componentWalk`; internal `init(path:resolution:probePassed:)` `:73` simulates a failed launch probe; the path must be absolute and free of `.`, `..`, empty components and NUL, else `.invalidPath` before `realpath`); `canonicalPath`, `identity`, `chain` (`/`…root inclusive, live walk, `:64`); `withDescriptor` `:105`; `relativePath(of:)` `:110`; `open` `:119`; `openWithChain(_:flags:) -> Opened {fd, chain}` `:143`; `openParent(_:) -> OpenedParent {parent, leaf, chain}` `:149`. Kernel-capability assertions belong in `TELLTALE_HW_TESTS`-gated tests only. Chains from `openWithChain`/`openParent` start **below** the root: full chain = `root.chain + opened.chain`.
- libproc from Swift precedent: `Sources/MonitorSensors/Process/CoalitionSensor.swift:151`.

## API to implement (plan §3.3; record final signatures with file:line — W3b codes against them)

```swift
struct CleanContext { home, permittedRoot, stagingDir: String; dataDirectories: [String]
                      trash: TrashMover; deleter: Deleter; evictor: Evictor; simctl: SimctlRunner; log: Logger }
final class Cleaner: Sendable { init(context:)
  func clean(_ items: [CleanupItem], tree: StorageTree, overlay: StorageTreeOverlay) -> AsyncStream<CleanEvent>
  func cancel(); func emptyTrash() -> AsyncStream<CleanEvent> }
Denylist.build(home:scanRoot:dataDirectories:) -> Denylist ; .check(…) -> DenyReason? ; .policy(for tree:) -> StoragePolicy
Staging(dir:) .sweep() -> SweepReport            // launch
UndoStore(file:) .append(_:) .prune(now:) .restore(_ record:) -> AsyncStream<CleanEvent>
InUseChecker(processes: ProcessPathSource) .inUse(_ items: [CleanupItem]) -> Set<Int32>
probes: DeleteWorker.slimSupported (launch probe)
```

## Spike-confirmed syscall choices (`docs/findings/storage-spikes.md`)

- **S1 opens** (§1): only via `TrustedRoot` (kernel `O_RESOLVE_BENEATH|O_NOFOLLOW_ANY` or the `O_NOFOLLOW` walk). No `realpath` + path-string deletion.
- **S6 renames** (§7): `renameatx_np(fromDirFd, leaf, toDirFd, leaf2, RENAME_EXCL | RENAME_NOFOLLOW_ANY)` — always (dir fd, leaf name). Macros import as `Int32`; the parameter is `UInt32`. `EEXIST` = name taken (never overwrite). `EINVAL` (flag unknown on an old kernel) → fail closed: skip item `.failed("rename unsupported")`. Leaf-name renames can't traverse symlinks even if a flag were ignored.
- **S2 delete** (§2): `removefileat(commitFd, name, state, REMOVEFILE_RECURSIVE | REMOVEFILE_RECURSIVE_SLIM)` with **only** `REMOVEFILE_STATE_ERROR_CALLBACK` (+ `ERROR_CONTEXT`). **Never** confirm/status callbacks with SLIM → `rc = -1, EINVAL`, nothing removed. SLIM gated by a launch probe on a scratch dir in staging (`EINVAL` → plain `RECURSIVE`). Read errno from `removefile_state_get(state, REMOVEFILE_STATE_ERRNO, …)`, not the return value (SLIM returned rc 0 with errno 66). Without an error callback the first failure aborts the whole removal — always install it; it records (path, errno) and returns `REMOVEFILE_SKIP`. Callback is `@convention(c)`; pass a context via `Unmanaged` of a final class holding a `Mutex` (no `@unchecked`). Cancel = `removefile_cancel(state)` from another thread (→ `ECANCELED`), only at app quit; a confirm-callback `STOP` is not a cancel. Never `REMOVEFILE_ALLOW_LONG_PATHS` (changes cwd, not thread-safe).
- **S4 trash** (§4): `TrustedRoot` open + identity check on the fd, then immediately `FileManager.trashItem(at: originalURL, resultingItemURL:)` (system writes Put Back info; never trash from staging; plain rename into `.Trash` gives no Put Back). Accepted window: URL re-resolution between check and call — comment it. Persist the resulting URL; trash parent = its parent dir (`~/.Trash` or a volume's `.Trashes/<uid>`), record its identity.
- **S5 in-use** (§5): `proc_listpids` (this user), per pid `proc_pidpath`, `proc_pidinfo(PROC_PIDVNODEPATHINFO)` (cwd), `PROC_PIDLISTFDS` + `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)` per vnode fd. Median ~19 ms. `EPERM` pids → counted as unknown holders (advisory); `ESRCH` mid-sweep → ignore. Kernel paths are canonical (`/private/var/...`): compare against canonical item paths.

## Tasks (commit per task, prefix `feat(storage-clean):`)

- [ ] **T1 `Denylist`** (live, never from scan data). Anchors: `/`, `~`, `~/Library`, every direct child of `~/Library` (listed live), `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/private`, `/opt/homebrew`, `/usr/local`, the scan root — target must not **be or contain** one. Protected: `~/Library/Keychains`, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Library/Mail`, `~/Library/Application Support/MobileSync`, own data (`~/Library/Application Support/dev.warden`, `…/dev.telltale`, `~/Library/Caches/dev.telltale-dev`, injected `dataDirectories`) — must not **be, contain, or be inside**. Per denylisted path D: live chain = component walk from `/` (`O_NOFOLLOW|O_DIRECTORY` per dir, `fstatat AT_SYMLINK_NOFOLLOW` on the last; `ENOENT` → chain of existing ancestors only). Per target: full chain = `root.chain + opened.chain` (+ target identity). is = target ∈ identities(D); contains = target ∈ chain(D); inside = any identity of the target's chain ∈ protected identities. Chain not establishable → `.unverifiable`. `policy(for:)` maps the same paths to tree nodes via `lookup` (advisory snapshot for the UI).
- [ ] **T2 Policy**: `.remove` outside `home` → `.removeOutsideHome`; outside `permittedRoot` (`relativePath(of:)` throws `.outsideRoot`) → `.outsideRoot`.
- [ ] **T3 `Staging`** journal (remove mode): `staging/pending/`, `staging/commit/` (0700, created on demand, opened once as fds). Per item: write sidecar `pending/<uuid>.json` {original parent path, parent identity, name, item identity}; `renameatx_np(parentFd, leaf, pendingFd, uuid, EXCL|NOFOLLOW_ANY)`; `fstatat(pendingFd, uuid)` identity vs `item.identity` (dev, ino, type); mismatch → rename back with `RENAME_EXCL` (`EEXIST` → leave in pending, `.rollbackCollision`, count in `stagingLeftovers`) and skip `.changedSinceScan`; match → `renameatx_np(pendingFd, uuid, commitFd, uuid, EXCL)`; delete sidecar. Staging `dev` ≠ item `dev` → `.stagingOtherVolume`, item untouched (no direct `removefile` fallback: it rebuilds paths via `F_GETPATH`). Worker deletes **only** `commit/`. Test seams (internal): device override; a hook after the pending rename to simulate a crash.
- [ ] **T4 Keep-parent**: open the item dir, list it live (fd-relative), detach each child individually through the journal; outcome aggregates `detachedBytes`, `committedChildren`, `skippedChildren`, `partial`, `removedNodes` (children that are tree nodes, via name under `item.nodeID`). Child bytes: tree size when the child is a node, else `fstatat` allocated size (`st_blocks * 512`) for files; record the rule.
- [ ] **T5 `DeleteWorker`**: ≤ 4 parallel deletes of `commit/` entries (S2). `EACCES` inside a user-owned committed tree → `u+w` on the failing parent (path is under our 0700 staging), one retry. After return: `fstatat(commitFd, name)` — gone → credit freed (`item.privateBytesExcludingLinks ?? allocBytes`, or the keep-parent children's bytes); still there → outcome `partial`, not credited, errors logged. Emits `.freed(bytes)` per finished entry.
- [ ] **T6 `Staging.sweep`** (launch): `commit/*` → delete; `pending/*` with sidecar → reopen original parent via `TrustedRoot`, verify parent identity, rename back (`EXCL`); otherwise leave and report (`SweepReport.leftovers`); never delete pending; orphan sidecars removed.
- [ ] **T7 Trash / evict / simctl / Empty Trash**: trash per S4; no Trash (`CocoaError.featureUnsupported` or the volume has no Trash) → `.noTrash`, never delete instead. Evict: identity check, then `FileManager.evictUbiquitousItem(at:)`. simctl: `xcrun simctl delete unavailable` via `Process`, 60 s timeout (terminate + `.failed("timeout")`). Empty Trash: journal-remove each child of `~/.Trash`; files owned by the user with `UF_IMMUTABLE` (`uchg`) get it cleared (`lchflags` inside staging), then retried. `TrashMover`, `Evictor`, `SimctlRunner`, `Deleter` are protocols/closure structs injected via `CleanContext` (fakes in tests).
- [ ] **T8 `Cleaner.clean` stream**: serial detach on a private queue/actor; `.item(outcome)` per processed item → `.freed` as deletions finish → exactly one `.finished(report)` (with `cancelled`, `undo` = trash entries) after detach stopped **and** the delete drain completed; then `finish()`. `cancel()` stops further detaching; committed items still drain. No subscriber (window closed) → keep draining. Vanished before detach: remove → success 0 B; trash → 0 B with note. Freed = Σ fully removed only; trashed bytes never in `freedBytes`.
- [ ] **T9 `UndoStore(file:)`** (`dataDirectory/storage-undo.json`, atomic write): `append(record)`; `restore(record)`: per entry `TrustedRoot(path: trashParentPath)`, verify `.identity == trashParentIdentity`; `fstatat` the trash leaf, identity == `entry.identity` else report, move nothing; open the original parent under `TrustedRoot(home or permittedRoot)` recreating missing components with `mkdirat` + `openat(O_NOFOLLOW|O_DIRECTORY)` (a symlinked component → refuse); `renameatx_np(trashParentFd, leaf, destFd, name, EXCL|NOFOLLOW_ANY)`, `EEXIST` → `name (restored)`, `name (restored 2)`, …; `.restored(itemID, finalPath)` then `.finished`. `prune(now:)`: drop entries whose trash item is gone or older than 7 d.
- [ ] **T10 `InUseChecker`** + live `ProcessPathSource` (S5). Match = path equal, or held path has prefix `itemPath + "/"` (never bare prefix).

## Tests (real temp dirs; injected `permittedRoot`, `home`, `dataDirectories`, staging dir; each catches a named bug; exact assertions)

Use canonical temp paths (`realpath` of the temp dir) so `/var` vs `/private/var` never decides a result. Clear `uchg` in test teardown. No sleeps: ordering via the stream and injected fakes.
- `StagingTests`: dir replaced after scan (new inode) → rolled back, original intact, `.changedSinceScan` — bug: deleting a different file. Stop after the pending rename (seam) → `sweep` restores to the original path — bug: user data lost in pending. Rollback collision (original name re-created) → left in pending, `.rollbackCollision`, never deleted. Staging on another device (seam) → `.stagingOtherVolume`, item intact. Sweep deletes `commit/` only.
- `DenylistTests`: target `Caches/dev.telltale-dev` whose child is the injected data dir, absent from the tree → `.denied(.protected)` — bug: trusting scan data. File inside `Keychains` → `.protected` (inside). `~/Library` and its parent → `.anchor`. Case variant and NFD variant spelling of a protected dir (temp APFS is case-insensitive) → refused. Scan root equivalent to `~/Library/Mail/V10`, trash a descendant → `.protected` (root ancestors in the chain). Unreadable ancestor (chmod 000) → `.unverifiable`.
- `CleanerTests`: keep-parent with a child created after scan → handled from the live listing, parent kept, counts right — bug: removing parent / missing children. Mid-path symlink pointing outside the root → refused, outside target intact. `.remove` outside `home` → `.removeOutsideHome`. `EACCES` subtree (dir 0555) → chmod retry, gone. Immutable (`uchg`) file inside a committed tree → not credited, outcome `partial`. Cancel before the first item → zero detached, one `.finished(cancelled: true)`; cancel between items (fake deleter gated by the test) → detached items drain and are freed, rest untouched; exactly one `.finished` — bug: hang or lost committed items. Vanished before detach: remove = success 0 B; trash = 0 B noted. Fake no-Trash → `.noTrash`, file present. `uchg` file in fake Trash removed by Empty Trash. `freedBytes` == Σ fully removed items only.
- `UndoTests`: restore; collision → `name (restored)`; missing parent recreated; substituted Trash entry (different inode, same name) → refused, reported; symlinked destination parent → refused, nothing written through the link; non-home Trash parent (temp dir standing in for `.Trashes/<uid>`) → restored.
- `InUseTests`: fake source holding `/a/b/c` marks item `/a/b`, not `/a/bc`; live source: this test process opens a temp file → its item is in use — bug: prefix lookalike / vnode path retrieval broken.
- Break-check: remove the post-rename identity check once → mismatch test red; revert. Quote both runs.

## Gates

- Iterate: `scripts/test.sh StagingTests` etc. (rerun only failed + touched suites).
- Merge gate: `scripts/ci.sh StagingTests DenylistTests CleanerTests UndoTests InUseTests` → `ci.sh: OK`; quote it.

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No `@unchecked`, no `as any`/lint disables, no swallowed errors: every per-item failure becomes a `SkipReason`/outcome and a `DiskTools.log` line; nothing thrown out of `clean`. Locks: `Mutex` / `OSAllocatedUnfairLock`. No AppKit (`FileManager` is Foundation — fine).
- Never test against real `~` or `~/.Trash` except the live trash path is unavoidable for `trashItem`: use a throwaway temp file and remove its Trash copy in teardown; prefer the fake `TrashMover`.
- Comments explain why (each accepted TOCTOU window gets one). No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines: pipe through `tail`/`grep`.
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefix `feat(storage-clean):`; message ends with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W2c.md`: Plan / Done (hashes) / Next / Interface deltas (final signatures, file:line) / Requests / Not verified (e.g. 14.x/15.x flag behavior, real `.Trashes/<uid>`, Finder Put Back) / Blockers.
- Don't merge; don't run Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, interface deltas, not verified.
