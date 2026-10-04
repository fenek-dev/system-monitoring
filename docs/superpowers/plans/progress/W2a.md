# W2a progress

Worktree `/Users/arturvorokov/Documents/Projects/telltale-storage-w2a`, branch `ws/storage-w2a` (from `feat/storage` @ c0be58c).

## Plan
T1 BulkAttrParser, T2 listers, T3 WorkQueue/Scanner/MarkerTable, T4 VolumeWatch, T5 ScanCache, T6 fixtures + smoke, T7 PrivateSizer, T8 FDA probe + ScanRoots, T9 probe --scan. All done.

## Done
- 63e9fe4 T1-T4, T6 (parser, listers, queue, scanner, volume watch, fixtures, ScannerTests, BulkParserTests, smoke).
- 4b97930 T5, T7, T8 (ScanCache, PrivateSizer, FDA probe, ScanRoots; ScanCacheTests, PrivateSizeTests).
- Final commit: probe `--scan`, partial-snapshot backoff, this file.
- Break-check (core): dropped `state.inFlight == 0` in `WorkQueue.complete()`:
  green run `Test run with 12 tests in 1 suite passed`; broken run `randomTreesRollUpToNaiveSums` (76 issues),
  `hardLinkBytesGoToTheShallowestOccurrenceEveryRun`, `nothingFinishesWhileAListingIsInFlight` red (78 issues in 12 tests); reverted, green again.
- Perf (release, M-series, warm): `telltale-probe --scan ~/Documents` -> entries 3,032,879, nodes 474,070, wall 15.06 s,
  RSS 355 MB, 201k entries/s; cache save 32 ms, load 50 ms (474k nodes). Spec target 1M <= 5 s = 200k/s: met.
  `--scan ~` did not finish: 8 workers blocked in `openat` on `~/Library/Containers/com.apple.Family/Data`
  (TCC "access data from other apps" prompt, nobody to answer it; FDA is off for the terminal). Not a scanner hang
  in the lister logic, but the engine should expect `open` to block on TCC prompts when FDA is missing.

## Next
Hand back to orchestrator.

## Interface deltas (W3b codes against these)
Files under `Sources/MonitorDiskTools/`.
- `DirectoryLister` (`Scan/DirectoryLister.swift`): `rootInfo() throws(ListError) -> ScanRootInfo {dev, fileID, mtime, volumeUUID}`,
  `open(_ rel: RelativePath?) throws(ListError) -> DirectoryHandle` (`~Copyable`, close = drop, nil = root),
  `list(_ dir: borrowing DirectoryHandle) throws(ListError) -> ListBatch {entries, done}` (one bulk call per batch, no `maxEntries`),
  `attributes(of: RelativePath) throws(ListError) -> ListedEntry` (single file, `fgetattrlist`).
  `ListedEntry {name: [UInt8], kind, fileID, mtime, addedTime, fileFlags, mountStatus, linkCount, allocBytes, privateBytes?, errorCode}`.
  `ListError {errno, op}`.
- `BulkLister(root: TrustedRoot, includePrivateSize: Bool = false)`, `InMemoryLister(_ items, batchSize:, info:, onList:, onOpen:)`
  (counters `opened`/`closed`, `listedPaths`), `FileManagerLister(rootPath:)`.
- `Scanner(lister: any DirectoryLister, threads: Int, home: String)` (`Scan/Scanner.swift`):
  `scan(root: ScanRoot, willUnmount: AsyncStream<String> = finished) -> AsyncStream<ScanEvent>`, `cancel()`,
  `static defaultThreadCount()`. Name clashes with Foundation's `Scanner`: spell `MonitorDiskTools.Scanner` where Foundation is imported.
  Stream buffers newest 16 events; the terminal event is sent by the last worker leaving (so after cancel the stream ends once every listing returned).
  The engine must call `ScanCache.save` only for `.finished`.
- `ScanCache(directory: URL)` (`Cache/ScanCache.swift`): `save(_ tree) throws(ScanCacheError)` (drops the old overlay sidecar),
  `saveOverlay(_:) throws(ScanCacheError)`, `load(root:volumeUUID:) -> (tree, overlay)?`, `static schema`.
- `PrivateSizer(lister:rootPath:)` (`Scan/PrivateSizer.swift`): `run(items:tree:isCancelled:) -> Output {items, linkGroupSizes}`;
  lister must be built with `includePrivateSize: true`.
- `FullDiskAccessProbe.check(home:) -> Bool`, `ScanRoots.available() -> [ScanRoot]` (`Scan/ScanRoots.swift`).

## Deviations from brief
- Directory listings are collected locally and committed in ONE `appendChildren` call (brief: commit in batches). Another worker can append between two batches, which breaks the builder's contiguity precondition; cancel is still checked between batches.
- `ScanCache` key hashes uuid + root kind + path (brief: uuid + path): `.home(p)` and `.folder(p)` otherwise share a file and each load deletes the other's cache as a mismatch.
- `PrivateSizer` marks an item `.estimate` when any counted file reports private < alloc (clone/snapshot sharing makes the sum a lower bound, per `SizeProvenance` docs); brief: `.exact` iff every file returned the bit.
- No `HardLinkSet` (builder dedupes; lock contention not visible in the 200k entries/s probe run).
- `InMemoryLister` closure params: `onList` first so an unlabeled trailing closure binds to it.
- Partial snapshots: copy the builder under the lock, sort outside it, back off to 4x snapshot time (a snapshot sorts every node; on a 4M-entry home it stalled the walk).
- Unsafe code is in `BulkAttrParser.swift` plus the buffer pool and volume-UUID lookup in `BulkLister.swift`.
- Symlinks are folded into small files unless a direct child of a `~/Library/*` keep dir (flag `.symlink`); system dirs (`.Spotlight-V100`, ...) are listed as `.skippedMount` nodes.
- Error entries (`ATTR_CMN_ERROR`) become `.directory|.restricted` nodes.
- Bundle extension table in `Scan/WalkRules.swift` (`packageExtensions`).

## Requests
None.

## Not verified
- Full `~` scan (TCC prompt blocked it); no run with FDA granted.
- Forced-removal path (`.revoke` source, real ENXIO) only through injected errors; revoke source never fired on real hardware.
- `.volume` scans and `/System/Volumes/Data`; `ScanRoots.available()` output only compiled, not inspected.
- `FullDiskAccessProbe` positive/negative cases (this terminal has no FDA: result "no").
- HW-gated smoke suite ran locally (5 tests green) but is not in `ci.sh`.
- Error-entry fixture is hand-built (documented in its JSON).

## Blockers
None.
