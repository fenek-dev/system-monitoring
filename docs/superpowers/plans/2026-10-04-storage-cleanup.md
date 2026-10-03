# Storage & Cleanup — implementation plan

> Agentic workers: one stream per agent, own worktree, steps `- [ ]`. TDD for parsers, arena, classifier, cleaner, layout math.

**Spec:** `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` (approved; corrections in §7 "Spec drift" below win).
**Integration branch:** `feat/storage` (worktree `../telltale-storage`). Progress: `docs/superpowers/plans/storage-progress.md`.
**Spikes:** `docs/findings/storage-spikes.md` (running in parallel). Plan never blocks on them: §6 gives a fallback per spike.
Paths are under `MonitorCore/` unless they start with `App/`, `Config/`, `scripts/`, `docs/`, `project.yml`, `SPEC.md`.

---

## 0. Rules (every stream)

- **Worktree:** `git -C ../telltale-storage worktree add ../telltale-storage-<id> -b storage/<id> feat/storage`. Work, test, commit only there. Rebase on `feat/storage` before handing back. Orchestrator merges (`--no-ff`, `merge: storage <id>`).
- **Ownership:** §2 matrix. Need a change in a file you don't own → note it in the progress file, add a local extension in your own files, orchestrator routes it. W1 types frozen after W1 merges; changes = ICR 018 addendum via orchestrator.
- **No AppKit** in `MonitorDiskTools`, `MonitorRuntime`, `MonitorLive`. AppKit needs → `@Sendable` closures in `StoragePlatform` (W1), built by `StorageActionsLive` (W3).
- **Concurrency:** ARCH §4 bans apply (`docs/ARCHITECTURE.md:216`); `@unchecked` only in `MonitorMocks` (`scripts/ci.sh:50-56`); locks = `OSAllocatedUnfairLock` (precedent `Sources/MonitorScreens/Shell/InMemoryDefaults.swift:13`). macOS 14 baseline (`Package.swift:19`) → no `Mutex`.
- **Logging:** `Logger(subsystem: "dev.telltale", category: "storage")` (subsystem precedent `Sources/MonitorRuntime/LivePipeline.swift:41`).
- **Tests:** only tests that catch a named bug (listed per stream). Rerun only failed suites + suites of touched sources. HW smoke suites (`TELLTALE_HW_TESTS=1`, precedent `Tests/MonitorSensorsTests/VolumeSmokeTests.swift:6`) never go in `ci.sh` args (`scripts/test.sh:35` fails on zero tests).
- **Gate per stream:** `scripts/ci.sh <your suites>` → `ci.sh: OK`, quote the line. Perf numbers advisory, reported not tuned.
- **Snapshots:** record with `TELLTALE_RECORD=1 scripts/test.sh <Suite>` (`Sources/MonitorSnapshotTesting/AssertSnapshot.swift:20`), view every new/changed PNG before committing; `ci.sh` is strict (`scripts/ci.sh:8`).
- **Commits:** prefix per stream (below); trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- **Review:** after each wave, Codex via T3 `delegate_task` (`gpt-6-astra`; `xhigh` for W2c cleaner/guardrails and W3 runtime lifetimes, `high` otherwise). Max 2 rounds.
- **Status:** each worker appends plan/done/next to `storage-progress.md` §Agents; ≤15-line final report.

---

## 1. Waves

```
W1 foundation (1 stream, sequential) ─┬─ W2a scanner+cache+probe ─┐
                                      ├─ W2b classifier ──────────┼─ W3a StorageModel ────┐
                                      ├─ W2c cleaner+undo+in-use ─┤  W3b runtime+live ────┼─ W4a page+SpaceMap ─┐
                                      └─ W2d UIKit ───────────────┘  W3c mocks ───────────┘  W4b Cleanup ────────┼─ W4 final: snapshots, screenshots
                                                                                              W4c sidebar/popover/catalog ┘
```

| Wave | Streams (≤4 concurrent) | Hard deps |
|---|---|---|
| W1 | W1 | — |
| W2 | W2a, W2b, W2c, W2d | W1 merged |
| W3 | W3a, W3b, W3c | W2a–c merged (W3b composes them); W3a/W3c need W1 only, may start once a W2 slot frees |
| W4 | W4a, W4b, W4c → W4-final (W4a owner) | W3 merged, W2d merged |

---

## 2. Ownership matrix (one owner per file per wave)

| Wave | Stream | Owns |
|---|---|---|
| W1 | W1 | `docs/icr/018-W1-storage-page.md`, `SPEC.md`, `docs/ARCHITECTURE.md`, `docs/design/DESIGN.md`, `docs/RULINGS.md`, `Config/**`, `.gitignore`, `project.yml`, `scripts/{install,ci}.sh`, `Package.swift`, `Sources/MonitorModel/Storage/**` (new), `Sources/MonitorModel/Services/Navigation.swift`, `Sources/MonitorModel/Sensors/Sampling.swift`, `Sources/MonitorScreens/Shell/{DashboardRoot,PageHeader,Sidebar}.swift`, `Sources/MonitorScreens/Pages/Storage/StoragePage.swift` (placeholder), `Sources/MonitorUIKit/Tokens/TTIcon.swift`, `Sources/MonitorUIKit/Gallery/GalleryPopover.swift`, `Sources/MonitorDiskTools/Support/FileDescriptor.swift`, `Sources/MonitorDiskTools/DiskTools.swift`, `Tests/MonitorModelTests/{UIVisibilityTests,StorageTreeTests}.swift`, `Tests/MonitorDiskToolsTests/Support/**`, `Tests/MonitorDiskToolsTests/Fixtures/.gitkeep`, goldens `shell-sidebar-calm.png`, `component-icons.png`, `component-sidebar.png` |
| W2 | W2a scan | `Sources/MonitorDiskTools/Scan/**`, `Sources/MonitorDiskTools/Cache/**`, `Sources/telltale-probe/**`, `Tests/MonitorDiskToolsTests/{Scanner,BulkParser,BulkListerSmoke,ScanCache,PrivateSize}*`, `Tests/MonitorDiskToolsTests/Fixtures/bulk/**` |
| W2 | W2b classify | `Sources/MonitorDiskTools/Classify/**`, `Tests/MonitorDiskToolsTests/{Classifier,BundleID,InstalledApps,BuildDir}*` |
| W2 | W2c clean | `Sources/MonitorDiskTools/Clean/**`, `Tests/MonitorDiskToolsTests/{Cleaner,Undo,InUse,Guardrail}*` |
| W2 | W2d UIKit | `Sources/MonitorUIKit/**` except `Tokens/TTIcon.swift` + `Gallery/GalleryPopover.swift`, `Tests/MonitorUIKitTests/**` (+ its `__Snapshots__`) |
| W3 | W3a model | `Sources/MonitorLive/Storage/**`, `Tests/MonitorLiveTests/Storage*` |
| W3 | W3b runtime | `Sources/MonitorRuntime/{TelltaleRuntime,LivePipeline,StoragePipeline}.swift`, `Sources/MonitorDiskTools/StorageEngine.swift`, `Sources/MonitorScreens/Shell/{ShellEnvironment,StorageActionsLive,SettingsStore}.swift`, `Sources/MonitorUIKit/Environment/EnvironmentValues+Telltale.swift`, `App/Sources/Composition/AppEnvironment.swift`, `App/Sources/Dashboard/DashboardWindowController.swift`, `Tests/MonitorRuntimeTests/Storage*`, `Tests/MonitorScreensTests/ShellStorage*` |
| W3 | W3c mocks | `Sources/MonitorMocks/{MockStorageState,MockDataProvider,ActionLog}.swift`, `Sources/MonitorRuntime/MockPipeline.swift`, `Tests/MonitorMocksTests/Storage*` |
| W4 | W4a page | `Sources/MonitorScreens/Pages/Storage/{StoragePage,StorageChrome,SpaceMapView,StorageStates}.swift` |
| W4 | W4b cleanup | `Sources/MonitorScreens/Pages/Storage/{CleanupView,CleanupLines,CleanConfirm}.swift`, `Tests/MonitorScreensTests/StorageCleanup*` |
| W4 | W4c shell | `Sources/MonitorScreens/Shell/{Sidebar,ScreenCatalog}.swift`, `Sources/MonitorScreens/Popover/{PopoverRoot,PopoverModel,PopoverRowView}.swift`, `Tests/MonitorScreensTests/{ShellComposition,Popover}Tests.swift`, `__Snapshots__/popover-*` re-records |
| W4 | W4-final (W4a) | `Tests/MonitorScreensTests/StorageSnapshotTests.swift`, `__Snapshots__/storage-*` |

`Sources/MonitorDiskTools/Support/**` frozen after W1 (W2a/W2c add their own helpers in their dirs).

---

## 3. Interfaces fixed in W1 (consumed concurrently by W2a/b/c, W3)

All in `Sources/MonitorModel/Storage/`, `public`, `Sendable`, explicit inits. Exact shapes; W1 may add members, not rename.

```swift
public typealias StorageNodeID = Int32

public struct StorageNodeFlags: OptionSet, Sendable { // UInt16
  directory, package, restricted, dataless /*cloud*/, skippedMount, hidden, sealed, hardLinked, symlink }
public struct StorageMarker: OptionSet, Sendable {    // UInt32, set by W2a per dir, read by W2b
  git, packageJSON, packageSwift, cargoToml, podfile, gradle, cmakeLists, cachedirTag, cmakeCache,
  swiftpmWorkspaceState /*.build/workspace-state.json*/, npmLock /*node_modules/.package-lock.json*/,
  pnpmModules /*.modules.yaml*/, yarnState /*.yarn-state.yml*/, podsManifest /*Pods/Manifest.lock*/ }

public struct FileIdentity: Sendable, Hashable, Codable { dev: Int32; ino: UInt64; isDirectory: Bool }

/// Immutable SoA snapshot. Reference type → swaps are one assignment; views compare `version`.
public final class StorageTree: Sendable {
  public let version: UInt64, root: ScanRoot, volumeUUID: UUID?, dev: Int32, scanDate: Date, lastEventId: UInt64
  public var count: Int
  // per node (index = StorageNodeID); parent < child; children contiguous [firstChild, firstChild+childCount)
  parent, firstChild, childCount: [Int32]; allocBytes: [UInt64] /*rolled up; restricted contributes 0*/
  smallBytes: [UInt64]; smallCount: [UInt32]; fileID: [UInt64]  // NEW vs spec: needed for §7.2 identity check
  mtime, subtreeMaxMtime, addedTime: [Int64]; flags: [StorageNodeFlags]; markerMask: [StorageMarker]
  nameOffset: [UInt32]; nameLength: [UInt16]; names: [UInt8]
  childOrder: [Int32]   // same ranges as children, sorted size desc, ties by name → IDs stay stable (spec "stored sorted" changed)
  childPrefix: [UInt64] // prefix sums over childOrder
  hardLinks: [HardLinkGroup]  // { bytes: UInt64, dirs: [StorageNodeID] } only for linkcount > 1 kept groups
  // accessors (W1 implements + tests)
  func name(_:) -> String; func path(_:) -> String; func size(_:) -> UInt64? /*nil if restricted*/
  func sortedChildren(_:) -> ArraySlice<Int32>; func cutoff(_ node:, minFraction: Double) -> Int /*binary search on childPrefix*/
  func isAncestor(_ a:, of b:) -> Bool; func lookup(path:) -> StorageNodeID?; func depth(_:) -> Int
  func externallyLinkedBytes(under:) -> UInt64  // §5.5: bytes of link groups with a link outside `under`
}
public struct StorageTreeBuilder {   // non-Sendable; W2a wraps in a lock; W3c/W2b/W2c tests use it directly
  init(root: ScanRoot, dev: Int32, volumeUUID: UUID?)
  mutating func appendChildren(of: StorageNodeID, _ records: [NodeRecord]) -> Range<Int32>
  mutating func setRestricted(_:), addSmall(_ node:, bytes:, count:), addHardLink(dir:, bytes:, key: FileIdentity)
  consuming func finalize(scanDate:, lastEventId:) -> StorageTree   // reverse-pass rollup, childOrder, prefix sums, link crediting at lowest depth
}
public struct NodeRecord: Sendable { name: [UInt8]; flags; allocBytes; fileID; mtime; addedTime; markers }

public enum ScanRoot: Sendable, Hashable, Codable { case home(String), folder(String), volume(path: String, name: String)
  var path: String; var allowsCleanup: Bool /* home only */ }
public struct ScanProgress: Sendable, Equatable { files: Int; bytes: UInt64; currentPath: String }
public enum ScanFailure: Sendable, Equatable, Error { case volumeRemoved, rootUnreadable(String), cancelled, io(String) }
public enum ScanEvent: Sendable { case progress(ScanProgress), partial(StorageTree), finished(StorageTree),
  classified(CleanupSet) /*NEW: emitted after classify, again when private sizes land*/, failed(ScanFailure) }

public enum CleanupCategory: String, CaseIterable, Sendable, Codable { case userCaches, leftovers, largeOld, developer, trash }
public enum SafetyTier: String, Sendable, Codable { case safe, review }
public enum DeleteMode: String, Sendable, Codable { case remove, trash, evict, simctl, none }
public struct OwnerApp: Sendable, Hashable, Codable { bundleID: String; name: String; appPath: String? }
public struct CleanupItem: Sendable, Identifiable, Equatable {
  id: Int32; parentID: Int32? /*group row*/; nodeID: StorageNodeID?; path: String; name: String
  category; tier; mode; identity: FileIdentity?; allocBytes: UInt64; privateBytes: UInt64?
  lastUsed: Date?; owner: OwnerApp?; runningApp: Bool; keepParent: Bool; note: String? /*e.g. docker prune hint*/ }
public struct CleanupSet: Sendable, Equatable { treeVersion: UInt64; items: [CleanupItem]; privateSizesFinal: Bool
  trashBytes: UInt64? /*nil unreadable*/ }
public struct ClassifyOptions: Sendable, Equatable { now: Date; largeBytes: UInt64 /*500 MB*/; oldBytes: UInt64 /*50 MB*/
  oldAge: TimeInterval /*6 mo*/; ignoredPaths: Set<String> }
public enum SkipReason: Sendable, Equatable, Codable { case inUse, changedSinceScan, denied /*denylist*/, outsideRoot,
  notPermitted, noTrash, vanished, failed(String) }
public enum CleanEvent: Sendable { case detached(Int32, bytes: UInt64), skipped(Int32, SkipReason), freed(UInt64), finished(CleanReport) }
public struct CleanReport: Sendable, Equatable { freedBytes, trashedBytes, evictedBytes: UInt64; skipped: [Int32: SkipReason]; undo: UndoRecord? }
public struct UndoRecord: Sendable, Equatable, Codable, Identifiable { id: UUID; date: Date; entries: [UndoEntry] }
public struct UndoEntry: Sendable, Equatable, Codable { originalPath: String; trashPath: String; identity: FileIdentity }
public struct StorageSummary: Sendable, Equatable, Codable { root: ScanRoot?; scanDate: Date?; reclaimableBytes: UInt64?; trashBytes: UInt64?
  static let empty }

/// AppKit pieces, injected (built by StorageActionsLive in MonitorScreens).
public struct StoragePlatform: Sendable { runningBundleIDs: @Sendable () async -> Set<String>
  appPaths: @Sendable (_ bundleID: String) async -> [String]; static let none }

/// Same shape as ProcessActions (Sources/MonitorModel/Services/ProcessActions.swift:38-61).
public struct StorageActions: Sendable {
  scan: @MainActor @Sendable (ScanRoot, ClassifyOptions) -> AsyncStream<ScanEvent>
  cancelScan: @MainActor @Sendable () -> Void
  loadCached: @MainActor @Sendable (ScanRoot, ClassifyOptions) async -> (StorageTree, CleanupSet)?   // NEW (§3.4 page reload)
  loadSummary: @MainActor @Sendable () async -> StorageSummary                                      // NEW (sidebar at launch)
  reclassify: @MainActor @Sendable (ClassifyOptions) async -> CleanupSet?                            // NEW (threshold change)
  checkInUse: @MainActor @Sendable ([CleanupItem]) async -> Set<Int32>                               // NEW (§7.1 step 2)
  clean: @MainActor @Sendable ([CleanupItem]) -> AsyncStream<CleanEvent>
  undo: @MainActor @Sendable (UndoRecord) -> AsyncStream<CleanEvent>
  emptyTrash: @MainActor @Sendable () -> AsyncStream<CleanEvent>
  availableRoots: @MainActor @Sendable () -> [ScanRoot]                                              // NEW (root chip)
  hasFullDiskAccess: @MainActor @Sendable () async -> Bool                                           // NEW
  ignore, revealInFinder: @MainActor @Sendable (String) -> Void; openFDASettings: @MainActor @Sendable () -> Void
  static let noop }
```

DiskTools entry points (signatures W2 streams implement; W3b composes them in `StorageEngine.swift`):

| Stream | Entry point |
|---|---|
| W2a | `protocol DirectoryLister: Sendable { func list(dirFd: Int32, path: String) throws(ListError) -> [ListedEntry] }`; `BulkLister`, `InMemoryLister`, `FileManagerLister`; `Scanner(lister:, threads:).scan(root: ScanRoot, isCancelled:) -> AsyncStream<ScanEvent>` (no `.classified`); `ScanCache(directory:).save(_ tree:) throws`, `.load(root:, volumeUUID:) -> StorageTree?`, `.loadSummaryHeader() -> (ScanRoot, Date)?`; `PrivateSizer.sizes(for: [CleanupItem], tree:) -> [Int32: UInt64]`; `FullDiskAccessProbe.check(home:) -> Bool`; `ScanRoots.available() -> [ScanRoot]` |
| W2b | `InstalledAppSet.build(home:, mdfind: @Sendable () -> [String], platform: StoragePlatform) async -> InstalledAppSet`; `SpotlightLastUsed.query(root:, minBytes:) -> [String: Date]`; `Classifier(home:, dataDirectory:, git: GitTracking, devTools: DevToolProbe).classify(tree:, installed:, lastUsed:, options:) -> CleanupSet` |
| W2c | `Cleaner(context: CleanContext).clean(_ items:, tree:) -> AsyncStream<CleanEvent>`; `.emptyTrash()`; `CleanContext { home, permittedRoot, stagingDir, trash: TrashMover, log }`; `UndoStore(file:).append/prune/restore(_:) -> AsyncStream<CleanEvent>`; `Staging.sweep(dir:)`; `InUseChecker(processes: ProcessPathSource).inUse(_ items:) -> Set<Int32>` |

---

## 4. Streams

### W1 — foundation (single stream, sequential, commit per step)

Prefixes: `docs(storage):`, `build(signing):`, `model:`, `build(disktools):`.

- [ ] **1.1 ICR 018** `docs/icr/018-W1-storage-page.md` (format = `docs/icr/009-W5b-disk-session-totals.md`): what (`DashboardPage.storage` + §3 types, Swift diff), why, affected streams. Row 18 in ARCH §11 table (`docs/ARCHITECTURE.md:1423-1442`).
- [ ] **1.2 Doc edits** (spec §3.6, corrected): SPEC ruling "cleanup in v1" under Rulings (`SPEC.md:10-41`), Categories `:52-53`, Data sources table `:55` (getattrlistbulk, MDQuery/mdfind, FDA probe, proc_pidinfo vnode paths), Actions `:96-97`, artboard list `:7` ("Storage: rendered, no artboard"). ARCH: §2 tree + target graph (`:59-157`) incl. `MonitorDiskTools → MonitorModel`, rule `:159` gains `MonitorDiskTools` (+ `MonitorLive`, `MonitorScreens`, App never import it); §4 table (`:201-210`) scanner thread pool row; §5.10/5.11 (`:1108`, `:1164`) storage types/actions/runtime; §7 (`:1327`) scan-memory row (13 MB arena/180k nodes, released on window close); §8 (`:1367`) test rows; §11 ICR row. DESIGN: §1.4 (`:237`) `storage` glyph row; §2.28 (`:514`) "N smaller items" rule; §2.29 (`:539`) table checkbox; §3.12 toast (`:999`) second action + 10 s with Undo; §3.1 (`:595`) "Free up space…" link copy; **new §3.17 Storage** (after §3.16 Overlay `:1152`): layout §4 of spec, 1100/1280 rules, states table; §5.8 (`:1333`) new row `Scanned {n} {unit} ago` (s/min/h/d, `just now` < 60 s). RULINGS: storage decisions made by this plan (ICR number, childOrder permutation, own-data exclusion).
- [ ] **1.3 Signing** (§3.7, no Team ID supplied): `Config/Signing.xcconfig` (`CODE_SIGN_IDENTITY = -`, `CODE_SIGN_STYLE = Manual`, last line `#include? "Local.xcconfig"`), `Config/Local.xcconfig.example` (`DEVELOPMENT_TEAM = XXXXXXXXXX`, `CODE_SIGN_IDENTITY = Apple Development`, `CODE_SIGN_STYLE = Automatic`), `.gitignore` += `Config/Local.xcconfig`; `project.yml`: delete `:11-12`, add target `configFiles: {Debug: Config/Signing.xcconfig, Release: Config/Signing.xcconfig}` under `Warden` (`:23`). `scripts/install.sh:42-45`: if `Config/Local.xcconfig` exists → keep xcodebuild's signature (no re-sign; `codesign -v` check, print identity), else current env/keychain/ad-hoc logic unchanged.
  Verify: `scripts/build.sh` → `BUILD SUCCEEDED`; `codesign -dv <app> 2>&1 | grep Signature` → `adhoc`; temp-copy example to `Local.xcconfig`, `xcodebuild -showBuildSettings … | grep -E 'CODE_SIGN_(IDENTITY|STYLE)'` → Apple Development/Automatic, delete copy. Not verified: real cert build (no Team ID).
- [ ] **1.4 Package**: target `MonitorDiskTools` (deps `MonitorModel`), test target `MonitorDiskToolsTests` (deps `MonitorDiskTools`, `MonitorModel`; `resources: [.copy("Fixtures")]`), `MonitorRuntime` deps += `MonitorDiskTools` (`Package.swift:71-76`), `telltale-probe` deps += `MonitorDiskTools` (`:81-84`). `Sources/MonitorDiskTools/DiskTools.swift` (namespace + log), `Support/FileDescriptor.swift` (`~Copyable` fd owner closing on deinit; `openDirectory(name:, in:)` = `openat(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`; `fstatat` → `FileIdentity`). `Tests/MonitorDiskToolsTests/Support/TreeFixture.swift` (DSL over `StorageTreeBuilder`: `dir("Library") { file("a", 2.mb) }`). `ci.sh` new grep: `import MonitorDiskTools` forbidden in `Sources/{MonitorLive,MonitorScreens,MonitorUIKit}` and `App/` (no import check exists today; ARCH rule `:159` is doc-only).
- [ ] **1.5 `model:` commit** — `Sources/MonitorModel/Storage/*.swift` per §3 (+ `StorageTreeBuilder` real impl), `DashboardPage.storage` after `.disk` (`Navigation.swift:4`), title "Storage" (`:8`), section `.system` (`:24-26`). Switches: `Sampling.swift:63` (`.storage` → `.none`, with `.gpu, .history`); `PageHeader.swift:114`/`:144` (`.storage` page-provided nil); `DashboardRoot.swift:49` (`case .storage: StoragePage()` — placeholder `TTEmptyState` "Not scanned yet", replaced by W4a); `Sidebar.swift:53` (`case .disk, .storage:` free space — the spec's no-scan fallback; W4c adds reclaimable); `TTIcon.swift:7` new `storage` case, svg `:13` (16-grid, stroke per DESIGN §1.4), `page()` `:97`. `GalleryPopover.swift:45-47` add `.storage` value. `UIVisibilityTests.swift:7-18` add `(.storage, [])`. No edits needed: `LaunchOptions.swift:65`, `telltale-probe/Options.swift:98` (rawValue), `TTSidebarItem.swift:26` (`default`), `ScreenCatalog.swift:43` (auto entry), `ShellSnapshotTests.swift:23`.
  Re-record goldens (only the new sidebar row/icon may differ — view diffs): `shell-sidebar-calm`, `component-icons`, `component-sidebar`.
- [ ] **Tests (W1)** `Tests/MonitorModelTests/StorageTreeTests.swift`:
  - rollup: grandchildren committed in a later batch than their parent's siblings still roll into root — bug: single forward pass/out-of-order batches undercount.
  - restricted child: parent size excludes it, `size(restricted) == nil` — bug: 0 shown as real size / NaN propagation.
  - `childOrder` desc, ties by name, IDs unchanged after finalize — bug: hover/cache keyed by id points at wrong node.
  - `cutoff(minFraction: 0.005)` at exact boundary (child == 0.5 %) — bug: off-by-one drops/keeps boundary tile.
  - hard link crediting: same `FileIdentity` added from depth 3 then depth 1 → bytes credited at depth 1 only, once; `externallyLinkedBytes(under:)` counts group with an outside link — bug: double count, order-dependent sizes.
  - `lookup(path:)` with trailing slash and non-existent component → nil — bug: denylist/ignore lookups match wrong node.
  - Break-check: flip rollup order once, confirm red, revert.
- [ ] **Gate:** `scripts/ci.sh StorageTreeTests UIVisibilityTests ShellSnapshotTests ComponentSnapshotTests ShellScreenCatalogTests`.

### W2a — scanner, arena fill, cache, probe

Prefix `feat(storage-scan):`. Files: `Scan/{BulkAttrParser,BulkLister,FileManagerLister,InMemoryLister,DirectoryLister,Scanner,WorkStack,HardLinkSet,MarkerTable,PrivateSizer,FullDiskAccessProbe,ScanRoots,VolumeWatch}.swift`, `Cache/ScanCache.swift`, `telltale-probe/{Options,Commands,main}.swift` + `Scan.swift`.

- [ ] Read `docs/findings/storage-spikes.md` (bulk PRIVATESIZE, cold scan); apply §6 rows S3.
- [ ] `BulkAttrParser`: walk `ATTR_CMN_RETURNED_ATTRS` mask per entry (spec §5.1); attrs list exactly §5.1 + `ATTR_CMN_FILEID`; one file, all unsafe pointer code here.
- [ ] `BulkLister` (getattrlistbulk, 256 KB buffer, `FSOPT_PACK_INVAL_ATTRS`), `FileManagerLister` (tests only), `InMemoryLister` (tree literal, per-dir latency/err injection).
- [ ] `Scanner`: N = `hw.perflevel0.physicalcpu` cap 8 (own sysctl; `HostCPUSensor.swift:158` precedent is in MonitorSensors, not importable) `Thread`s at `.userInitiated`; LIFO `WorkStack` under `OSAllocatedUnfairLock`; cancel flag per pop; per-thread `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, …OFF)`; walk rules §5.2 (dataless, mount/trigger skip, no symlink follow, skip `.Spotlight-V100`/`.fseventsd`/`.DocumentRevisions-V100`, packages leaf, unreadable → restricted); keep rules §5.3 (dirs, files ≥ 1 MB, all direct children of `~/Library/{Application Support,Caches,Containers,Group Containers,Preferences,Saved Application State,HTTPStorages,WebKit,Logs}`); `MarkerTable` raw-byte compare; `subtreeMaxMtime` excluding build-dir names; hard links `HardLinkSet` 16 shards, only linkcount > 1 → `addHardLink`; `.partial` at 3 Hz (root children + current level), `.progress` ≤ 10 Hz.
- [ ] `VolumeWatch`: `DispatchSource.makeFileSystemObjectSource(rootFd, .revoke)` + `ENXIO/EIO/ENODEV` from listing → cancel, `.failed(.volumeRemoved)`; close worker fds on cancel.
- [ ] `ScanCache`: header (magic, schema, root, volume UUID, date, `lastEventId` via `FSEventsGetCurrentEventId`, counts) + raw arrays; file `dataDirectory/storage-scan-<fnv(volumeUUID+root)>.bin`; temp + `rename`; `mmap` read; mismatch/torn → nil + delete. Never written for partial/cancelled/failed scans.
- [ ] `PrivateSizer` (candidates only, utility queue; §6 S3). `FullDiskAccessProbe` (`open(~/Library/Safari, O_RDONLY)` → `EPERM` = no FDA). `ScanRoots.available()` (`getfsstat`, drop `MNT_DONTBROWSE`/`MNT_SNAPSHOT`, Data volume → "Macintosh HD").
- [ ] `telltale-probe --scan <root> [--threads N]`: entries, nodes, wall, RSS (`Options.swift:7` command enum, `:72` parse).
- [ ] Bulk fixtures: `TELLTALE_RECORD_BULK=1` smoke run writes `Fixtures/bulk/{dir-then-file,file-then-dir,error-entry}.bin` + expected JSON.
- Tests (`ScannerTests` on `InMemoryLister` unless noted):
  - random trees (seeded, 50 seeds) scanned with 8 threads + random latency equal naive recursive sums; parent < child; children contiguous — bug: concurrent batch commits interleave/lose children.
  - hard links: 2 links at depth 4 and 2 → credited once at depth 2, identical across 20 runs — bug: thread-timing-dependent sizes, double count.
  - small files fold into parent `smallBytes/Count`; `~/Library/Preferences/*.plist` kept as nodes — bug: leftovers classifier can't see plists.
  - markers + `subtreeMaxMtime` ignores fresh `node_modules` mtime — bug: stale project looks fresh.
  - `EACCES` dir → restricted, scan continues — bug: scan aborts or shows 0 B.
  - dataless dir never listed (lister asserts not called) — bug: materializing iCloud.
  - mount point / trigger dir never listed — bug: walks into `/Volumes` / autofs hang.
  - `.app` walked for size, presented with childCount 0 — bug: package internals in map.
  - cancel mid-scan → stream ends `.failed(.cancelled)` within one listing, no cache file — bug: cancelled partial cached.
  - lister throws `ENXIO` → `.failed(.volumeRemoved)`, no cache — bug: partial tree cached as complete.
  - `BulkParserTests`: recorded buffers decode to expected entries for dir→file, file→dir, error entry — bug: fixed-layout assumption misreads sizes after a dir entry.
  - `ScanCacheTests`: round-trip equality of all arrays incl. names; other root / other volume UUID / schema+1 → nil; truncated file → nil — bug: loading wrong/torn cache.
  - `BulkListerSmokeTests` (HW-gated): temp tree via real getattrlistbulk == `FileManagerLister`; symlink not followed; hard link count; PRIVATESIZE availability print.
- Perf (advisory, report): `telltale-probe --scan ~` wall/RSS; 1M-entry target ≤ 5 s warm; cache load for ~300k nodes < 100 ms.
- Gate: `scripts/ci.sh ScannerTests BulkParserTests ScanCacheTests`.

### W2b — classifier, installed apps, Spotlight

Prefix `feat(storage-classify):`. Files: `Classify/{BundleID,InstalledAppSet,SpotlightLastUsed,Classifier,CategoryRules,BuildDirRules,DevToolProbe,GitTracking}.swift`.

- [ ] `BundleID.normalize` (§6.1) + `isAppleOwned`.
- [ ] `InstalledAppSet` (§6.2): mdfind via `Process` (injected for tests), `/Applications` + `~/Applications` 2 levels, Steam `steamapps/common`, drop `~/.Trash`/`/Volumes`/AppTranslocation, nested bundles (LoginItems, Helpers, PlugIns `*.appex`, `Wrapper/`); `owns(id)` = equal / dot-boundary prefix or suffix / same first two components; `<TeamID>.<word>` never flagged; unmatched → `platform.appPaths`.
- [ ] `SpotlightLastUsed`: one scoped `MDQuery` (`kMDItemFSSize > 50 MB`, scope root), CoreServices only.
- [ ] `Classifier` (§6.3 table): priority Developer > User Caches > Leftovers > Large & Old; largest matching subtree only; nested de-dupe by ancestry; tier/mode per row. Exclusions: Apple-owned, system cache list, own data: `dev.telltale*`, `dev.warden*`, `dev.telltale-dev` (run.sh data dir lives in `~/Library/Caches`, `scripts/run.sh:16`), and any path that is or contains the injected `dataDirectory` (staging lives there). Large & Old: last used = max(mtime, addedTime, Spotlight); materialized iCloud → `.evict`. Dev: fixed paths (DerivedData, Homebrew/npm/yarn/pnpm/pip/cargo/gradle/CocoaPods caches, JetBrains), DeviceSupport keep newest per platform, Archives > 180 d, simctl item only if `DevToolProbe.xcodeSelectOK`, Docker `Docker.raw` mode `.none` + note, build dirs (§6.3 last-but-two row) with `GitTracking.hasTrackedFiles(project:, dir:)` (`git ls-files -z -- <dir>`, candidates only, 5 s timeout → treat as tracked). Trash = `~/.Trash`. `ignoredPaths` drop items. Hard links: `privateBytes` capped by `allocBytes − externallyLinkedBytes(under:)`.
- Tests:
  - `BundleIDTests` table: spec §8 IDs (`group.com.apple.VoiceMemos.shared`, `74J34U3R6X.com.apple.iWork`, `243LU875E5.groups.com.apple.podcasts`, `UBF8T346G9.Office`, `*.widgetextension`) — bug: Apple group containers flagged as leftovers.
  - ownership: prefix/suffix/vendor match, `com.foo` vs `com.foobar` not owned, TeamID-only names never flagged — bug: installed app's data deleted as leftover.
  - `InstalledAppsTests`: hits under `~/.Trash`, `/Volumes`, AppTranslocation dropped; nested `.appex` id added — bug: trashed app keeps data "owned"/helper data flagged.
  - leftovers age 89 d vs 91 d boundary (injected `now`) — bug: off-by-one age gate.
  - caches: Apple + system list + own data dir (`dev.warden`, `dev.telltale-dev/<wt>`, staging) excluded; `com.apple.dt.Xcode` allowed — bug: deleting our own staging/store or system caches.
  - Large & Old: 500 MB exact included; 50 MB + 6 mo old; recent `addedTime` beats old mtime; excluded `~/Library`, `CloudStorage`, `.app`, `.photoslibrary`, hidden dirs — bug: Photos library or freshly downloaded file offered for trash.
  - build dirs: needs `.git` ancestor + marker + 30 d staleness + no tracked files; under `~/.cargo` or `~/Library` excluded — bug: deleting a tracked `build/` dir or a live project's deps.
  - priority + nesting: `node_modules` inside a leftover dir appears once (Developer); parent of an item never also selected — bug: bytes counted/deleted twice.
  - DeviceSupport keeps newest per platform — bug: removing the only symbols for the connected device.
  - Break-check: flip one ownership rule, confirm red, revert.
- Perf (advisory): classify 180k-node tree < 50 ms.
- Gate: `scripts/ci.sh ClassifierTests BundleIDTests InstalledAppsTests BuildDirTests`.

### W2c — cleaner, guardrails, undo, in-use

Prefix `feat(storage-clean):`. Files: `Clean/{Cleaner,Guardrails,Denylist,SafePath,Staging,DeleteWorker,TrashMover,Evictor,SimctlRunner,UndoStore,InUseChecker,ProcessPathSource}.swift`.

- [ ] Read spikes file; apply §6 S1, S2, S4, S5.
- [ ] `SafePath.open(path, beneath: root)`: per-component `openat(O_NOFOLLOW)` from root fd (S1 decides `RESOLVE_BENEATH`/`O_NOFOLLOW_ANY` addition). No `realpath`, no path-string delete.
- [ ] `Denylist` built at clean time as `Set<FileIdentity>` (spec §7.4 list + scan root + `dataDirectory`); refuse target that is or contains one (contains via `tree.isAncestor` on `lookup` of denylisted paths). Allowed: inside `~` (Cleanup) or scan root (Space Map trash); `permittedRoot` injected.
- [ ] Remove mode: `renameatx_np(parentFd, name, stagingFd, unique, RENAME_EXCL|RENAME_NOFOLLOW_ANY)` → `fstatat` identity vs scan; mismatch → rename back, `.skipped(.changedSinceScan)`; `keepParent` → each child; different `dev` → direct `removefile` after same identity check. `DeleteWorker` ≤ 4 parallel `removefile` (`REMOVEFILE_RECURSIVE` + S2), `removefile_state` cancel/error cb, `EACCES` in user-owned staged tree → `u+w` retry; never `ALLOW_LONG_PATHS`. `Staging.sweep` at launch.
- [ ] `TrashMover` protocol (live: `FileManager.trashItem` after identity check; no Trash → `.noTrash`, never fall back to delete); `Evictor` (`evictUbiquitousItem`); `SimctlRunner` (`xcrun simctl delete unavailable`, 60 s). Empty Trash = remove mode on `~/.Trash` children, `uchg` user-owned → clear + retry.
- [ ] `UndoStore` `dataDirectory/storage-undo.json`: restore via `renameatx_np(RENAME_EXCL)`, recreate parents, collision → `name (restored)`, gone → reported; prune when trash item gone or > 7 d.
- [ ] `InUseChecker`: `proc_listpids(PROC_UID_ONLY, getuid())`, per pid `PROC_PIDFDVNODEPATHINFO` + `PROC_PIDVNODEPATHINFO` (cwd) + `proc_pidpath`; item in use iff an open path has the item path + "/" as prefix or equals it. S5 budget.
- [ ] Reports: per-item errors into `CleanReport`, never thrown; freed = Σ privateBytes (fallback alloc) of fully removed items; trashed never counted as freed; `os_log` line per path.
- Tests (real temp dir, injected `permittedRoot`):
  - `CleanerTests`: detach + identity mismatch (replace dir between scan and clean) → rolled back, skipped, original intact — bug: deleting a different file at the scanned path.
  - keep-parent: cache dir children gone, dir stays — bug: removing `~/Library/Caches/<app>` breaks app sandbox expectations.
  - symlink in a middle component pointing outside root → refused, target outside untouched — bug: symlink escape deletes outside `~`.
  - denylist is/contains: `~/Library` itself and a parent of `~/Library/Keychains` refused — bug: catastrophic delete.
  - case/NFD variant path of a denylisted dir refused (APFS case-insensitive temp) — bug: string-compare denylist bypass.
  - `EACCES` (dir `0500` inside staged tree) → chmod retry succeeds — bug: half-deleted staging left forever.
  - `uchg` file in fake Trash → cleared and removed — bug: Empty Trash silently partial.
  - fake `TrashMover` returning no-Trash → `.skipped(.noTrash)`, file still present — bug: fallback to permanent delete.
  - vanished before detach: remove → success 0 B; trash → 0 B noted — bug: error toast for already-gone item.
  - launch sweep deletes leftover staging dir — bug: crash leaks GBs in staging.
  - freed bytes = Σ removed private sizes, excludes skipped and trashed — bug: overstated "Freed".
  - `UndoTests`: restore; collision → `name (restored)`; missing parent recreated; item emptied from Trash → reported, not silent.
  - `InUseTests`: open file `/a/b/c` marks item `/a/b`, not `/a/bc` — bug: prefix false positive/negative.
  - Break-check: remove the identity check once, confirm the mismatch test goes red, revert.
- Gate: `scripts/ci.sh CleanerTests UndoTests InUseTests GuardrailTests`.

### W2d — UIKit

Prefix `feat(uikit):`. Files: `Treemap/{TTSpaceMap,SpaceMapHitTest}.swift` (new), `Treemap/TreemapLayout.swift`, `Components/{TTTable,TTToast,TTTableCheckbox}.swift`, `Gallery/**` (new gallery items).

- [ ] `TreemapLayout`: `squarify(presorted:)` skipping the sort at `TreemapLayout.swift:41`; incremental row min/max so each growth step is O(1) (today `worstRatio` scans the row per step, `:47-77`). Old entry point unchanged for `TTTreemap` (`TTTreemap.swift:12-13`, `[AppShare]`).
- [ ] `TTSpaceMap` (spec §4.7): `Tile {id: Int32, value, label, kind: normal/smaller/restricted}`, one `Canvas` (precedent `TTChartCanvas`, `TTAreaChart.swift:115`), labels only where they fit, `onContinuousHover` over cached rects, hover overlay layer reading only a `hoveredID` binding, single tooltip, cached hatch, no drill-down animation, `.accessibilityChildren` "{name}, {size}, {share}%". Layout cached per (node id, size) by caller key.
- [ ] `TTTable`: optional `hover: Binding<Row.ID?>`; row `==` (`TTTable.swift:309`) includes `isHovered` so hover redraws two rows (today per-row `@State hovering`, `:306`, `:347`). `TTTableCheckbox` cell (DESIGN §2.29 checkbox style, `Toggle(.checkbox)` tinted accent), Space toggles.
- [ ] `TTToast`: optional second action (`Show`, `Empty Trash`) + `undo`; `lifetime(hasUndo:)` 10 s else 4 s (`TTToast.swift:10`). Keep `init(_:undo:)` source-compatible (callers `PopoverRoot.swift:37`, `W5aPageSupport.swift:437`, `ThermalsPage.swift:865`).
- [ ] Gallery items `space-map`, `space-map-restricted`, `table-checkbox`, `toast-actions` + `ComponentSnapshotTests.ids` (`ComponentSnapshotTests.swift:11-14`).
- Note: confirm dialog needs no change — `TTConfirmDialog` already wraps multi-line `message` (`TTConfirmDialog.swift:52-56`); message builder is W4b.
- Tests:
  - `TreemapLayoutTests` (existing file): presorted path == current output on 200 seeded inputs (rects equal ±1e-9) — bug: refactor changes layouts.
  - `SpaceMapHitTestTests`: points on shared edges / inside "smaller" tile / gutter → expected id or nil — bug: wrong tile hovered/drilled.
  - `TTTableTests`: hover binding change alters `==` for exactly old+new hovered rows — bug: whole table re-renders per mouse move (perf regression).
  - snapshots: new gallery items (visual check first).
  - perf advisory: 10k-child derived state (cutoff + layout of capped set) < 2 ms; 10k Cleanup-like lines diff.
- Gate: `scripts/ci.sh TreemapLayoutTests SpaceMapHitTestTests TTTableTests ComponentSnapshotTests`.

### W3a — StorageModel (MonitorLive)

Prefix `feat(storage-model):`. Files: `Sources/MonitorLive/Storage/{StorageModel,ScanProgressState,SpaceMapState,CleanupState,HoverState}.swift`.

- [ ] `@MainActor @Observable StorageModel(actions:)`; sub-objects per spec §3.3 (each `@Observable`, model holds `let` refs). Phases: `.idle(summary)`, `.loadingCache`, `.scanning(previous: StorageTree?)`, `.ready`, `.failed(ScanFailure)`. Tree swap = one assignment; `SpaceMapState` keyed by `tree.version`.
- [ ] Cleanup: checked `Set<Int32>` (default = `.safe` && !runningApp && mode != .none), running selected bytes/count updated O(1) per toggle; sorted lines cached per (category, sort, expansion, treeVersion); `.detached` removes item, updates totals and tree view in place (no rescan); clean/undo tasks owned here; latest `UndoRecord` kept.
- [ ] Lifetimes: `pageDidChange` no-op for tasks; `windowDidClose()` → cancel scan, let clean finish current item, release tree + cleanup set, keep `StorageSummary`; `pageDidAppear()` → `loadCached` off-main.
- [ ] `classifyOptions` set by the page from SettingsStore (Live can't import Screens; `SettingsStore` is `Sources/MonitorScreens/Shell/SettingsStore.swift`).
- Tests `StorageModelTests` (mock streams, no disk):
  - checked totals after toggle, detach of a checked item, and undo — bug: running total drifts/double-subtracts.
  - `.detached` for a checked item removes it from checked set — bug: Clean re-sends deleted ids.
  - rescan keeps previous tree visible until `.finished`; `.failed` keeps previous — bug: map blanks during rescan.
  - window close: scan cancelled, tree nil, summary kept; page switch: scan continues — bug: background scanning / lost summary.
  - observation isolation: progress tick doesn't fire a `SpaceMapState`/`CleanupState` observer (pattern `Tests/MonitorLiveTests/LiveModelTests.swift:8-18`) — bug: whole page re-renders at 10 Hz.
- Gate: `scripts/ci.sh StorageModelTests`.

### W3b — runtime composition, StorageActionsLive, app wiring

Prefix `feat(storage-runtime):`.

- [ ] `MonitorDiskTools/StorageEngine.swift`: holds last tree + installed set + Spotlight map; utility serial queue for classify/private-size/Spotlight/installed-app (spec §3.5); builds `StorageActions` core closures (scan → classify → `.classified` → private sizes → `.classified(final)` → cache save on success only); launch: `Staging.sweep`, `UndoStore.prune`.
- [ ] `MonitorRuntime/StoragePipeline.swift`; `TelltaleRuntime` exposes `storage: StorageModel`, `storageActions: StorageActions` (`TelltaleRuntime.swift:34-76`); `make(…, storagePlatform:)` param (default `.none`); live → engine, mock → W3c canned actions (via `MockPipeline`, owned W3c: W3b only calls `MockPipeline.storageActions`; W3c provides it — agree signature in progress file day 1).
- [ ] `MonitorScreens/Shell/StorageActionsLive.swift` (next to `ProcessActionsLive.swift`): wraps core actions + `revealInFinder` (`NSWorkspace.activateFileViewerSelecting`), `openFDASettings` (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`), `ignore` → SettingsStore; `platform()` → `StoragePlatform` (`NSWorkspace.runningApplications`, `urlsForApplications(withBundleIdentifier:)`).
- [ ] `SettingsStore` keys `storage.ignoredPaths`, `storage.largeThreshold`, `storage.oldThreshold` (style of `SettingsStore.swift:19-20`).
- [ ] `ShellContext` gains `storage`, `storageActions` with defaults (`ShellEnvironment.swift:10-44`) so `ScreenCatalog.context` (`ScreenCatalog.swift:60-67`) compiles unchanged; inject `.environment(storage)` + `\.storageActions` (`:84-95`); `@Entry storageActions: StorageActions = .noop` in `EnvironmentValues+Telltale.swift:7`.
- [ ] App: `AppEnvironment.swift:49` (`TelltaleRuntime.make`), `:70` (`ShellContext`) pass platform + context fields; `DashboardWindowController` close → `storage.windowDidClose()`.
- Tests:
  - `StorageRuntimeTests` (real temp tree, permitted root = temp): scan → classify yields a cache item → clean → file gone, `.finished` freed > 0, cache written; cancelled scan writes no cache — bug: wiring drops events / caches partial results.
  - `ShellStorageTests`: `ignore(path)` persists in `InMemoryDefaults` and the next reclassify omits it — bug: ignore not honored.
- Gate: `scripts/ci.sh StorageRuntimeTests ShellStorageTests RuntimeTests`.

### W3c — mocks

Prefix `feat(storage-mocks):`.

- [ ] `MockStorageState` (`empty`, `scanning`, `map`, `cleanup`, `noFDA`): deterministic `StorageTree` via `StorageTreeBuilder` (~2k nodes, realistic names: Library/Caches, Developer/DerivedData, node_modules, Movies), matching `CleanupSet` across all 5 categories incl. running-app and in-use items, `MockDataProvider.referenceDate` (`MockDataProvider.swift:48`).
- [ ] `MockDataProvider.storageActions(log:)` next to `processActions(log:)` (`:231`): canned streams, never touches disk; `ActionLog.Kind` += `scan, clean, undo, emptyTrash, ignore, revealInFinder` (`ActionLog.swift:8`).
- [ ] `MockPipeline.storageActions` for `--mock` runs.
- Tests `StorageMockTests`: `clean(ids)` logs exactly the ids passed and emits `.detached` per id then `.finished` — bug: confirm-flow tests pass vacuously.
- Gate: `scripts/ci.sh StorageMockTests`.

### W4a — page shell, Space Map, states

Prefix `feat(storage-ui):`. Replaces W1 placeholder.

- [ ] `StoragePage` per DESIGN §3.17: header trailing via `pageHeaderTrailing` (`PageHeader.swift:44`, precedent `ProcessesPage.swift:71`): root chip, `Scanned … ago` (injected `now`), Scan/Rescan/Cancel; FDA banner (`TTAlertBanner`, dismissible per session); stat strip (Capacity/Used/Free via `ShellFormat.freeSpace` `ShellFormat.swift:11`/Purgeable/Reclaimable/Trash; Purgeable drops at 1100 width, `ShellStyle.dashboardMinSize` `ShellStyle.swift:45`); `TTSegmented` mode switch (`TTSegmented.swift:7`); Cleanup disabled outside `~` with caption.
- [ ] `SpaceMapView`: breadcrumb, `TTSpaceMap` (2 cols) + children `TTTable` (1 col; Items column drops at 1100), shared `HoverState`, smaller-items rule, restricted hatch, row/tile menu (Reveal · Move to Trash… · Ignore; Trash disabled + reason on denylisted), keyboard (arrows, Return, ⌘[ / Backspace).
- [ ] `StorageStates`: §4.5 table (`TTEmptyState` `TTEmptyState.swift:7`).
- Gate: `scripts/ci.sh --no-tests` + render check `scripts/render.sh storage calm`.

### W4b — Cleanup mode + clean flow

- [ ] `CleanupView`: category card + item table (`sortsRows: false`, model-owned lines; precedent `TTTableStyle.processes` `TTTable.swift:402`), checkbox, tier/In use badges, owner `TTAppTile` (reuses `AppIconCache`, `TTAppTile.swift:86`; MainActor today — no off-main warming in v1), group child rows, Large & Old threshold `TTSegmented`, sticky footer `Selected … · N items` + `Clean…`.
- [ ] `CleanConfirm`: §7.1 flow — `checkInUse` → untick + notice → `await confirm?.confirm(…)` (`ConfirmDialogHost.swift:49`) with multi-line message (delete permanently / move to Trash / remove downloads lines, in-use list capped at 5 + "+N more") → `clean` → footer `Cleaning 12/37…` / `Freeing…` → toast (`Freed X · Moved Y to Trash`, `Empty Trash`, `Show`, `Undo`).
- Tests `StorageCleanupTests` (via `MockDataProvider.storageActions(log:)` + `ActionLog`): confirm cancelled → no `clean` logged; confirmed → logged ids == checked minus newly in-use — bug: deleting without confirm / deleting in-use items. Message builder: 7 in-use → 5 names + "+2 more"; trashed bytes never in "Freed" — bug: misleading copy.
- Gate: `scripts/ci.sh StorageCleanupTests`.

### W4c — sidebar, popover, catalog

- [ ] `Sidebar.value` takes `StorageSummary` (`Sidebar.swift:52`): `{n} GB reclaimable` after a scan, else free space (current `.disk` branch `:69-73`).
- [ ] Popover Disk section link `Free up space…` → `appCommands.openDashboard(.storage)` (`AppCommands.swift:5`); row model `PopoverModel.swift:82-84`. Re-record affected `popover-*` goldens.
- [ ] `ScreenCatalog`: entries `storage-scanning`, `storage-map`, `storage-cleanup`, `storage-nofda` + `-1100` variants (size 1100×720); `dashboard(_:scenario:)` (`ScreenCatalog.swift:76`) takes a size + storage state.
- Tests: sidebar value "12 GB reclaimable" vs no-scan free space (`ShellCompositionTests`) — bug: stale/wrong sidebar value; popover link opens `.storage` — bug: link opens Disk.
- Gate: `scripts/ci.sh ShellCompositionTests PopoverTests`.

### W4-final (W4a owner, after W4a–c merge)

- [ ] `StorageSnapshotTests`: `assertScreen` (`Tests/MonitorScreensTests/Support/ScreenTestSupport.swift:62`) for `storage`, `storage-scanning`, `storage-map`, `storage-cleanup`, `storage-nofda` at 1280 and 1100, `.calm`.
- [ ] Render every id with `scripts/render.sh <id> calm`, Read each PNG, compare against DESIGN §3.17 text (no artboards — user decision); fix, re-render.
- [ ] Real app: `scripts/build.sh && scripts/run.sh --open-dashboard storage`, scan `~`, screenshot (`screencapture -l <winid>`) Space Map, Cleanup, confirm dialog, toast; with mock `scripts/run.sh --mock calm --open-dashboard storage`. No FDA in ad-hoc dev build → banner state verified live; full-access state not verifiable without signing.
- [ ] Clean a throwaway temp cache dir under `~/Library/Caches/dev.telltale-test-<n>` via the UI; verify gone + toast.
- Gate: `scripts/ci.sh StorageSnapshotTests StorageCleanupTests ShellCompositionTests PopoverTests ComponentSnapshotTests`.

---

## 5. Merge order and checkpoints

1. W1 → `feat/storage`; Codex review; fix P1s.
2. W2a–d in any order as green; Codex review (W2c `xhigh`).
3. W3a, W3c, then W3b (rebased); review (`xhigh`).
4. W4a–c, then W4-final; review; screenshots attached to progress file.
5. Ask user: merge `feat/storage` → `dev` (Mixer WIP overlap, §8 Q1–Q2).

---

## 6. Spike-dependent choices (read `docs/findings/storage-spikes.md`; default = fallback)

| # | Spike | If yes | Fallback (default until confirmed) | Owner |
|---|---|---|---|---|
| S1 | `RESOLVE_BENEATH` honored on macOS 14 | add to `openat` flags in `SafePath` | per-component `openat(O_NOFOLLOW)` from the root fd (always done anyway) + `O_NOFOLLOW_ANY` on any full-path open; symlink-escape test is the guard | W2c |
| S2 | `REMOVEFILE_RECURSIVE_SLIM` on 14 | OR into flags | `REMOVEFILE_RECURSIVE` only; if flag set and `removefile` returns `EINVAL`, retry once without and remember | W2c |
| S3 | bulk returns `ATTR_CMNEXT_PRIVATESIZE` | `PrivateSizer` walks candidate subtrees with `getattrlistbulk` + `FSOPT_ATTR_CMN_EXTENDED` | per-file `getattrlist` over candidate subtrees on the utility queue, 10 s budget; unavailable/over budget → keep allocated bytes, `privateSizesFinal = false`, UI keeps "≈" | W2a |
| S4 | Finder "Put Back" works for `trashItem` items | DESIGN copy may mention Put Back | Undo via our `UndoStore` only; copy never mentions Put Back | W2c, W1 doc |
| S5 | `proc_pidinfo` pass ≤ 300 ms | run inline at Clean | run off-main at Cleanup open (prewarm) + again at Clean; > 1 s → footer "Checking open files…" spinner before confirm; never skipped | W2c, W4b |
| S6 | cold-scan time (`sudo purge`, user) | — | advisory only; report number | W2a |

---

## 7. Spec drift (verified against `feat/storage` @ fa55ba7)

| Spec says | Actual / correction |
|---|---|
| ICR `016` (§3.2, §3.6, §9) | ICR-16 = Overlay (`docs/ARCHITECTURE.md:1442`); 017 claimed by network-monitor spec (`…network-monitor-design.md:402`). Use **ICR 018** |
| DESIGN "new §3.16 Storage" | §3.16 = Overlay (`DESIGN.md:1152`). Use **§3.17** |
| `ARCH:157` UI-import rule | `docs/ARCHITECTURE.md:159`; doc-only, no automated check → W1 adds `ci.sh` grep |
| App imports `project.yml:35-36` | `project.yml:38-40`; app is now **Warden** (`project.yml:1,23`) |
| `ci.sh:40` `@unchecked` | `scripts/ci.sh:50-56` |
| `install.sh:40` ad-hoc re-signs every install | `scripts/install.sh:42-45` already signs with `WARDEN_SIGN_IDENTITY` or first keychain "Apple Development", else ad-hoc. Change = skip re-sign when `Local.xcconfig` exists |
| `PageHeader.swift:142` | switch `:114`, page-provided branch `:144` |
| `TTIcon.swift:35,105` | enum `:7`, svg switch `:13`, `page()` `:97-109` |
| Switch list incl. `LaunchOptions`, `telltale-probe/Options.swift`, `ShellSnapshotTests` | no edit: rawValue parsing (`LaunchOptions.swift:65`, `Options.swift:98`), fixed args (`ShellSnapshotTests.swift:23`). Real extra work: goldens `shell-sidebar-calm`, `component-icons`, `component-sidebar`; `GalleryPopover.swift:45-55` |
| `TTAreaChart.swift:78` `TTChartCanvas` | defined `TTAreaChart.swift:115` |
| `TTTable` `:282-286` equality, `.processes` `:350` | row `==` `TTTable.swift:309`, hover is per-row `@State` `:306/:347`, `.processes` `:402` |
| Confirm dialog needs multi-line message (`ConfirmDialogHost.swift:7-13`) | `TTConfirmDialog.swift:52-56` already wraps multi-line text; only a message builder (W4b) |
| `EnvironmentValues+Telltale.swift` (location implied Screens) | `Sources/MonitorUIKit/Environment/EnvironmentValues+Telltale.swift:7-13`; `ShellContext` is in `Shell/ShellEnvironment.swift:10` |
| `SettingsStore` keys backed for `MonitorDiskTools` | `SettingsStore` lives in `MonitorScreens` (`Shell/SettingsStore.swift:19-20`) → thresholds/ignore passed as `ClassifyOptions` |
| Exclude own caches `dev.telltale*` | data dir is `dev.warden` (`App/Sources/Composition/AppEnvironment.swift:76`), legacy `dev.telltale` (`:81`), dev runs use `~/Library/Caches/dev.telltale-dev/<wt>` (`scripts/run.sh:16`) — inside User Caches scope; exclude all + `dataDirectory` |
| `storage-scan.bin` single file | one file per root → `storage-scan-<hash>.bin` |
| DESIGN §5.8 relative time "Scanned 2 h ago" | §5.8 (`DESIGN.md:1333-1342`) has no relative-time rule → W1 adds one |
| Arena fields (§5.3) | add `fileID` (identity check §7.2 needs dev/ino from scan); "children stored sorted" → `childOrder` permutation (stable IDs) |
| `StorageActions` (§3.3) | missing `loadCached`, `loadSummary`, `reclassify`, `checkInUse`, `availableRoots`, `hasFullDiskAccess`; `ScanEvent` lacks `.classified` — added in §3 |
| Icons "warmed off-main" | `AppIconCache` is internal `@MainActor` (`TTAppTile.swift:86`); v1 reuses it as-is |
| ARCH §2 `App/Sources/Services/ProcessActionsLive.swift` (`:74`) | actual `Sources/MonitorScreens/Shell/ProcessActionsLive.swift` (spec correct, ARCH stale; W1 fixes ARCH) |
| Verified OK | `Sidebar.swift:52`, `TreemapLayout.swift:41`, `TTToast.swift:10-23`, `project.yml:11-12`, `ShellStyle.swift:45`, `VolumeSensor.swift:14` (no `requires`, 10 s), `TTTreemap.swift:12-13` (`[AppShare]`), `Package.swift:19` (macOS 14) |

---

## 8. Unresolved questions

1. Mixer WIP on `dev` bumps `platforms` to `.macOS(.v15)` and edits `Package.swift`, `TTIcon.swift`, `PopoverRoot.swift`, `project.yml` — same files as W1/W4c. Merge Mixer first (then storage rebases; spikes on 14 matter less) or storage first?
2. ICR number: take 018 (016 used, 017 reserved by network spec) — OK, or renumber network to 018?
3. No Team ID → FDA grant resets on every dev rebuild; W4-final can't verify the full-access state. Acceptable, or will you grant FDA to `/Applications/Warden.app` after an `install.sh` run for a final check?
