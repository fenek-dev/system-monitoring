# W2a brief — scanner, arena fill, scan cache, private sizes, probe

Self-contained. Source of truth order: **W1 code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §4 W2a, §6). If a W1 type differs from this brief, the code wins; record the mismatch in your progress file. A Codex review of W1 may land small contract fixes before you start — re-read the cited files.

Paths below are under `MonitorCore/` unless they start with `docs/`, `scripts/`, `App/`.

## Goal

`MonitorDiskTools/Scan` + `Cache`: a parallel `getattrlistbulk` walker that fills W1's `StorageTreeBuilder` and emits `ScanEvent`s; a binary scan cache with an overlay sidecar; a private-size pass for cleanup items; FDA probe; scan-root list; `telltale-probe --scan`. W3b composes these in `Engine/StorageEngine.swift` (not yours).

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w2a`, branch `ws/storage-w2a` (created from `feat/storage` by the orchestrator after W1 merged). Work, test, commit only there. Rebase on `feat/storage` before handing back. **Do not merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (if `git status` then lists `.codegraph/`, add it to `$(git rev-parse --git-common-dir)/info/exclude`); else `codegraph sync -q`. Use `codegraph explore "<symbols>"` before grep.

## Ownership

Own (create/edit freely):
- `Sources/MonitorDiskTools/Scan/**`, `Sources/MonitorDiskTools/Cache/**`, `Sources/telltale-probe/**`
- `Tests/MonitorDiskToolsTests/{Scanner,BulkParser,BulkListerSmoke,ScanCache,PrivateSize}*`, `Tests/MonitorDiskToolsTests/Fixtures/bulk/**`
- `docs/superpowers/plans/progress/W2a.md`

Must not touch: everything else — in particular `Sources/MonitorModel/**`, `Sources/MonitorDiskTools/{DiskTools.swift,Support/**}`, `Tests/MonitorDiskToolsTests/Support/**` (W1), `Classify/**` (W2b), `Clean/**` (W2c), `Engine/**` (W3b), `Package.swift`, `scripts/**`, docs other than your progress file.
Escalation: a needed change in a file you don't own → implement a local extension in your own files (e.g. `extension StorageTree` in `Scan/`), record it under "Requests" in your progress file; orchestrator routes it.

## W1 APIs you consume (verify; code wins)

Model (`Sources/MonitorModel/Storage/`):
- `StorageNodeFlags` `StorageBasics.swift:6-25` (`directory, package, restricted, dataless, skippedMount, hidden, sealed, symlink, buildDir`). `buildDir` (`:25`) is new vs plan: set it on build-output dirs (`node_modules`, `.build`, `target`, `Pods`, `build`, `cmake-build-*`); `finalize` then keeps their mtimes out of the parent's `subtreeMaxMtime` (`StorageTreeBuilder.swift:142`). A `.restricted` node is zeroed after its own descendants roll into it, so nothing appended below it reaches its ancestors.
- `StorageMarker` `StorageBasics.swift:30-47` (file name per bit in the trailing comments). `FileIdentity` `:51` (+ `init(_ st: stat)` in `Support/FileDescriptor.swift:68`). `NodeRecord` `:67`, inits `:78` (`[UInt8]` name) / `:88` (`String`). `LinkOccurrence` `:96`, `HardLinkGroup` `:111` (`identity`, `linkCount`, `allocBytes`, `privateBytes?`, `provenance`, `occurrences`).
- `StorageTreeBuilder` `StorageTreeBuilder.swift:7`: `init(root:dev:volumeUUID:rootFileID: = 0, rootMtime: = 0)` `:32`; `appendChildren(of:_:) -> Range<Int32>` `:46` (one listing's children must be contiguous: consecutive calls for the same dir with nothing appended in between — precondition at `:52`); `setDirFacts(_:markers:flags:)` `:60`; `setRestricted(_:)` `:65`; `addSmall(_:bytes:count:maxMtime:)` `:70`; `addLink(_:linkCount:bytes:occurrence:privateBytes: = nil)` `:81` (dedupes by identity itself, `:84`; keeps the largest `linkCount` seen; `privateBytes` = PRIVATESIZE if the listing returned it → group provenance `.exact`); `snapshot()` `:101`; `consuming finalize(scanDate:lastEventId:)` `:106`.
- **Hard-link contract** (W1 progress `docs/superpowers/plans/progress/W1.md`, "Interface deltas"): a file with linkcount > 1 is passed with `NodeRecord.allocBytes == 0` if kept; if folded, it still counts in `addSmall` `count` but not in its bytes; its bytes go only through `addLink` (occurrence = file node if kept, else the containing dir node, which marks it folded at dir depth + 1). Pass the file's real `st_nlink` every time (all filesystem links, incl. outside the scan). `finalize` sorts occurrences by (depth, path) and credits once at the first.
- **Private sizes of links** (T7): the tree is immutable after `finalize`; the private-size pass returns per-group sizes as `CleanupSet.linkGroupSizes: [Int32: LinkGroupSize]` (`Cleanup.swift:111`, `:122`; `.exact` only with real PRIVATESIZE bytes). `ReclaimAccumulator` uses them over the tree's values.
- `StorageTree` `StorageTree.swift:9`; public memberwise `init(root:volumeUUID:dev:scanDate:lastEventId:parent:…:linkGroups:version: = nextVersion())` `:48` (for the cache loader); `nextVersion()` `:44`; `nodeCount` `:89`; `path(_:)` `:101`; `lookup(path:)` `:151`.
- `StorageTreeOverlay` `StorageTreeOverlay.swift:31` (Codable; `init(tree:)` `:69`; every read/mutation `throws(StorageOverlayError.treeMismatch)` for another tree version); `rebased(onto:) throws` `:76` — call it when loading a sidecar against a freshly decoded tree (versions are process-local); it checks the scan identity (root, volume UUID, scan date, node count), so the cache loader must decode `scanDate` exactly (bit pattern of the `Double`).
- `ScanRoot` `StorageScan.swift:3`, `ScanProgress` `:22`, `ScanFailure` `:34`, `ScanEvent` `:41`.
- `CleanupItem` `Cleanup.swift:54` (`privateBytesExcludingLinks`, `sizeProvenance`, `linkGroupIndices`, `keepParent`), `SizeProvenance` `:24`.
- `StoragePlatform.willUnmount` `StorageServices.swift:11` (the engine passes its stream into `Scanner.scan`).

DiskTools support (`Sources/MonitorDiskTools/`):
- `DiskTools.log` `DiskTools.swift:7` — the only logger.
- `SafePathError` `Support/FileDescriptor.swift:4`; `FileDescriptor` (`~Copyable`, closes in deinit) `:19`, `open(at:_:flags:)` `:32`, `identity()` `:51`, `identity(of:)` `:58`.
- `RelativePath` `Support/SafePath.swift:6` (`init(validating:)` `:9`, `init(components:)` `:15`, `confined(_:under:)` `:29`); `TrustedRoot` `:49`, `init(path:resolution:)` `:68` (rejects non-absolute / `.` / `..` / empty-component / NUL spellings before `realpath`), `identity`/`chain`, `withDescriptor` `:105`, `relativePath(of:)` `:110`, `open(_:flags:)` `:119` (kernel mode = one `openat` with `O_RESOLVE_BENEATH|O_NOFOLLOW_ANY`, else per-component `O_NOFOLLOW` walk).
- Test DSL `Tests/MonitorDiskToolsTests/Support/TreeFixture.swift:12` (`build` `:103`; kept links carry `fileID == ino`, generated ids start at `1 << 40`) — read-only for you.

Package: `MonitorDiskTools` depends on `MonitorModel` only (`Package.swift:71`); test target has `resources: [.copy("Fixtures")]` (`Package.swift:120-124`). `getattrlistbulk`, `setiopolicy_np`, `getfsstat` come from `Darwin`; `FSEventsGetCurrentEventId` from `CoreServices`. If a symbol isn't importable, stop and escalate (Package.swift is not yours).

## Design decisions fixed for you

- `DirectoryLister` (plan §3.3 shape `list(_ dir: borrowing FileDescriptor, path:, maxEntries:) throws(ListError) -> ListBatch`) needs an **open step** so `InMemoryLister` can count opens/closes. Recommended: lister owns `open(_ rel: RelativePath) throws(ListError) -> DirectoryHandle` where `DirectoryHandle: ~Copyable` wraps `FileDescriptor?` + a token and reports close in `deinit`; `list(_ dir: borrowing DirectoryHandle, path:, maxEntries:) -> ListBatch { entries; done: Bool }` (bulk calls continue on the same fd). Record the final shape in your progress file (W3b reads it).
- Directory opens go through `TrustedRoot.open(rel, flags: O_RDONLY|O_DIRECTORY)` of the scan root (fd-relative, no symlinks). Queue items carry the dir's node id + relative components, not fds; the worker that opens a fd closes it after the listing (ARCH §4 row, `docs/ARCHITECTURE.md:211`). No fd crosses threads.
- `HardLinkSet` (plan): the builder already dedupes by identity (`StorageTreeBuilder.swift:80`). Skip `HardLinkSet` unless the builder lock shows contention in the probe; record the decision.
- Kept file threshold: `allocBytes >= 1_000_000` (decimal, DESIGN §5.3 storage units). Document as a constant.
- `Scanner` needs `home: String` (for the `~/Library/*` keep rule) — add it to the init: `Scanner(lister:threads:home:)`.
- Package dirs (`.app`, `.photoslibrary`, `.musiclibrary`, `.fcpbundle`, `.xcarchive`, `.pvm`, `.utm`, + other bundle extensions you list in one table): flag `.package`, walk for size but append no children — fold all descendant bytes into the package node with `addSmall` (links: occurrence = package node). Never inside a package: markers, kept nodes.

## Spike-confirmed syscall choices (`docs/findings/storage-spikes.md`)

- **Bulk attrs** (spec §5.1, spikes §6): `commonattr = RETURNED_ATTRS|NAME|ERROR|OBJTYPE|FILEID|MODTIME|ADDEDTIME|FLAGS`, `dirattr = ATTR_DIR_MOUNTSTATUS`, `fileattr = ATTR_FILE_LINKCOUNT|ATTR_FILE_ALLOCSIZE`; options `FSOPT_PACK_INVAL_ATTRS`. **Layout varies per entry** (dirs omit file attrs): walk each entry by its own returned mask; never assume a fixed layout. Packing order and the position of `ATTR_CMN_ERROR`: verify in `man getattrlist`/`sys/attr.h`, don't guess; recorded fixtures settle it. `NAME` is an `attrreference_t` (offset relative to the reference itself); use `loadUnaligned`. All unsafe pointer code in `BulkAttrParser.swift` only.
- **PRIVATESIZE** (spikes §3): `forkattr = ATTR_CMNEXT_PRIVATESIZE` **plus** `FSOPT_ATTR_CMN_EXTENDED` (without it the bit is never returned); value is an `off_t` after file attrs. Read only if the returned `forkattr` bit is set → `.exact`; else `.estimate` (alloc). Dirs return private = 0 (not recursive) — sum files yourself. Clones share extents: private is a per-file lower bound, not additive.
- **Dataless** (spikes §8): every worker thread calls `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`; rc ≠ 0 → log, continue (dataless dirs are never entered anyway). Never list a dir whose `ATTR_CMN_FLAGS` has `SF_DATALESS`; flag `.dataless`.
- Mounts: skip dirs with `DIR_MNTSTATUS_MNTPOINT` or `DIR_MNTSTATUS_TRIGGER` (flag `.skippedMount`). Skip `.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`. Never follow symlinks (flag `.symlink`, no size walk).
- Threads (spikes §6): `min(8, sysctl hw.perflevel0.physicalcpu)` `Thread`s, `qualityOfService = .userInitiated`. Never a GCD concurrent queue, never `.background`. Measured ~125k entries/s warm (8 threads).
- Unmount (spec §5.2): ordinary eject = `willUnmount` path matching the root's volume → cancel promptly; forced removal = `DispatchSource` `.revoke` on the root fd, or `ENXIO`/`EIO`/`ENODEV` from a listing → `.failed(.volumeRemoved)`. `EACCES`/`EPERM` on a dir → `setRestricted`, continue.

## Tasks (commit per task, prefix `feat(storage-scan):`)

- [ ] **T1 `BulkAttrParser`** — parse one `getattrlistbulk` buffer into entries (name bytes, type, fileID, mtime, addedTime, flags, mountStatus, linkCount, allocBytes, privateBytes?, errno?). Accept: `BulkParserTests` green on recorded fixtures (T6).
- [ ] **T2 `DirectoryLister` + `BulkLister` (256 KiB buffer, bounded batches) + `InMemoryLister` (tree literal, injectable per-dir latency/block/throw, open/close counters) + `FileManagerLister`.** Accept: compile; `InMemoryLister` reports `opened == closed` in every Scanner test.
- [ ] **T3 `WorkQueue` + `Scanner` + `MarkerTable`** — LIFO stack in `Mutex` (`import Synchronization`) with `queued`/`inFlight` counters; wake via `DispatchSemaphore` (signal per push; on done/cancel signal once per thread). Done ⇔ `queued == 0 && inFlight == 0` checked under the lock after a worker finishes committing. Cancel flag checked per pop and between batches. Builder in `Mutex<StorageTreeBuilder>`; commit a dir's children in its batches (contiguous); `setDirFacts` after the last batch (markers by raw name-byte compare, `MarkerTable`); `.hidden` for dot-names / `UF_HIDDEN`; `.buildDir` by name. Keep rules (spec §5.3): dirs, files ≥ 1 MB, every direct child of `~/Library/{Application Support,Caches,Containers,Group Containers,Preferences,Saved Application State,HTTPStorages,WebKit,Logs}`; others → `addSmall` with max mtime. `lastEventId = FSEventsGetCurrentEventId()` taken **before** the walk. Events: `.progress` ≤ 10 Hz, `.partial(snapshot())` ~3 Hz, one terminal `.finished`/`.failed`, then finish the stream. `cancel()` → `.failed(.cancelled)`. Accept: ScannerTests green.
- [ ] **T4 `VolumeWatch`** — root-volume matching for `willUnmount`, revoke source, errno mapping. Accept: unmount tests green.
- [ ] **T5 `ScanCache(directory:)`** — `save(_ tree:)` / `saveOverlay(_:)` / `load(root:volumeUUID:) -> (StorageTree, StorageTreeOverlay)?`. File `storage-scan-<fnv1a64(uuid + root.path) hex>.bin`: header (magic, schema, root (Codable), volume UUID, scan date, `lastEventId`, counts) + raw arrays; write temp + `rename`; read via `mmap` (`Data(bytesNoCopy:…)` or `withUnsafeBytes`), validate every count/length against file size before copying; any mismatch/truncation → delete file, return nil. Sidecar `<same>.overlay.json`, atomic write; missing sidecar → `StorageTreeOverlay(treeVersion: tree.version)`; loaded sidecar → `.rebased(onto: tree)`. Never called for partial/cancelled/failed scans (the engine decides; document it on `save`). Accept: ScanCacheTests green.
- [ ] **T6 Bulk fixtures** — `BulkListerSmokeTests` (HW-gated, `@Suite(.serialized, .enabled(if: env["TELLTALE_HW_TESTS"] == "1"))`, precedent `Tests/MonitorSensorsTests/VolumeSmokeTests.swift:11`) builds a deterministic temp tree; with `TELLTALE_RECORD_BULK=1` it writes raw buffers → `Tests/MonitorDiskToolsTests/Fixtures/bulk/*.bin` + expected `*.json`. Record from a temp tree only (never your home). An error entry is hard to provoke: a hand-built buffer is acceptable if documented in the fixture JSON.
- [ ] **T7 `PrivateSizer`** — for `[CleanupItem]` (+ tree, scan root): bulk-walk each item's subtree (keep-parent items: the dir's children) requesting PRIVATESIZE; sum non-link files into `privateBytesExcludingLinks`; files with linkcount > 1 are skipped (counted via `linkGroupIndices`, set by W2b) and their PRIVATESIZE goes into `CleanupSet.linkGroupSizes[groupIndex]` (`.exact` only when the bit was returned, else `privateBytes: nil, .estimate`); single-file items via `getattrlist`/`fgetattrlist` with `FSOPT_ATTR_CMN_EXTENDED`. Provenance `.exact` if every file returned the bit, else `.estimate`; unreadable → keep `allocBytes`, `.estimate`. Returns updated items; cancellable between items. Runs on the caller's queue (engine: serial `.utility`).
- [ ] **T8 `FullDiskAccessProbe.check(home:) -> Bool`** (open `~/Library/Safari` `O_RDONLY|O_DIRECTORY`: `EPERM`/`EACCES` → false; success → true; `ENOENT` → true and log) and **`ScanRoots.available() -> [ScanRoot]`** (`.home(NSHomeDirectory())` first; `getfsstat(MNT_NOWAIT)`, drop `MNT_DONTBROWSE`/`MNT_SNAPSHOT`; `/System/Volumes/Data` → `.volume(path:, name: "Macintosh HD")`; others → last path component).
- [ ] **T9 `telltale-probe --scan <root> [--threads N]`** — `Command` enum `Sources/telltale-probe/Options.swift:7`, parse switch `:72`, usage text, command in `Commands.swift`. Prints entries, nodes, wall s, RSS MB, entries/s. Run `--scan ~` once; put the numbers in your progress file (advisory; spec target 1M ≤ 5 s, spikes predict ≈ 8 s).

## Tests (each catches a named bug; deterministic; exact assertions; table-driven for data variants)

`InMemoryLister` unless noted. Use a seeded RNG (`SplitMix` precedent in `Tests/MonitorUIKitTests/TreemapLayoutTests.swift:10`), injected latency via the lister (no `sleep` in assertions — block/unblock with semaphores the test controls).
- `ScannerTests`:
  - 50 seeds of random trees, 8 threads + random per-dir latency: sizes == naive recursive sums; `parent[i] < i`; children contiguous — bug: concurrent commits interleave/lose children.
  - root listing blocked until the test releases it → no `.finished` while blocked — bug: done detected while `queued == 0` but root in flight.
  - cancel while all 8 workers are inside listings (lister blocks) → last event `.failed(.cancelled)`, `opened == closed`, stream finishes — bug: hang / fd leak.
  - 2 links of one inode at depths 4 and 2 → bytes credited at the depth-2 occurrence, identical tree sizes over 20 runs — bug: timing-dependent sizes.
  - small files fold into `smallBytes`/`smallCount`; `~/Library/Preferences/x.plist` (tiny) kept as a node — bug: leftovers can't see plists.
  - markers set on the listing dir; fresh `node_modules` (flag `.buildDir`) doesn't raise the project's `subtreeMaxMtime` — bug: stale project looks fresh.
  - table: `EACCES` dir → `.restricted`, scan continues; `SF_DATALESS` dir never listed (lister records listed paths); mount/trigger dir never listed; `.app` dir is a leaf with folded size — bugs: abort / iCloud download / walk into `/Volumes` / package internals shown.
  - unmount: injected `willUnmount` root path → `.failed(.volumeRemoved)`; lister throws `ENXIO` → same — bug: scan keeps the volume busy / partial tree treated as complete.
- `BulkParserTests` (recorded fixtures): dir→file, file→dir order, error entry, PRIVATESIZE present/absent — bug: fixed-layout misread.
- `ScanCacheTests` (temp dir): round-trip all arrays + `linkGroups` + overlay (after `rebased`); other root / other UUID / schema + 1 / truncated file → nil and file deleted — bug: wrong or torn cache loaded.
- `BulkListerSmokeTests` (HW-gated, never in `ci.sh` args): real bulk listing == `FileManagerLister` on a temp tree; symlink not followed; clone pair (`cp -c`) private sizes 0/0, plain file private == alloc (spikes §3).
- Break-check (core): flip the done condition (drop the `inFlight` term) once → delayed-root test red; revert. Quote both runs in progress file.
- No test for: `ScanRoots`, FDA probe, probe CLI (no named bug beyond smoke; verify by running).

## Gates

- Build: `scripts/build.sh`. Tests while iterating: `scripts/test.sh ScannerTests` etc. (rerun only failed suites + suites of touched files).
- Merge gate: `scripts/ci.sh ScannerTests BulkParserTests ScanCacheTests` → must print `ci.sh: OK`; quote it. `ci.sh` greps forbid `&-`, `map(Double.init)`, `@unchecked` (`scripts/ci.sh:35-67`).
- Perf (advisory, report only): `swift run telltale-probe --scan ~`; cache load ~300k nodes < 100 ms.

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No `@unchecked`, no `as any`/lint disables, no swallowed errors (`try?` only where the failure is truly irrelevant, with a why-comment). Locks: `Mutex` or `OSAllocatedUnfairLock` (precedent `Sources/MonitorScreens/Shell/InMemoryDefaults.swift:13`). No AppKit in `MonitorDiskTools`.
- Comments explain why, not what; match surrounding density. No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines: pipe through `tail`/`grep`.
- 2 failed attempts with the same approach → stop, re-diagnose, note it in progress.
- Commits: prefix `feat(storage-scan):`; message ends with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W2a.md`: Plan / Done (commit hashes) / Next / Interface deltas (final `DirectoryLister`, `Scanner`, `ScanCache`, `PrivateSizer` signatures with file:line — W3b codes against these) / Requests (needed changes in files you don't own) / Not verified / Blockers. Update after each task.
- Don't merge; don't run Codex reviews (orchestrator does). Final report to the orchestrator ≤ 15 lines: branch, last commit, ci.sh result line, perf numbers, interface deltas, not-verified list.
