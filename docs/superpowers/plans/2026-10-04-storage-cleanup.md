# Storage & Cleanup — implementation plan (rev 2, review r1 applied)

> Agentic workers: one stream per agent, own worktree, steps `- [ ]`. TDD for parsers, arena, overlay, reclaim math, classifier, cleaner, layout.

**Spec:** `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` (approved; this plan's §3 types and §7 "Spec drift" win).
**Integration branch:** `feat/storage` (worktree `../telltale-storage`, rebased on `dev` incl. Mixer `67af40f`).
**Spikes:** `docs/findings/storage-spikes.md` (`a550db4`, measured on macOS 26.5) — choices in §6.
**Platform:** deployment target macOS 15 (`MonitorCore/Package.swift:19`, `project.yml:5`). Runtime capability probes only for flags whose SDK headers carry no availability (spikes §1, §2, §7); probes fail closed.
Paths are under `MonitorCore/` unless they start with `App/`, `Config/`, `scripts/`, `docs/`, `project.yml`, `SPEC.md`.

---

## 0. Rules (every stream)

- **Threat model (binding, keeps designs simple):** guardrails protect against stale scan data, our own bugs, ordinary concurrent changes by the user/apps (files replaced, moved, re-created between scan and clean), and path spelling issues (case, Unicode normalization, `..`, symlinks, prefix lookalikes). They do **not** defend against a hostile same-user process — it can already delete anything the user can. So: identity checks right before each step, accepted small TOCTOU windows where an API takes a URL (noted where they occur), no privilege separation.
- **Worktree:** `git -C ../telltale-storage worktree add ../telltale-storage-<id> -b storage/<id> feat/storage`. Work, test, commit only there; rebase on `feat/storage` before handing back. Orchestrator merges (`--no-ff`, `merge: storage <id>`).
- **Progress:** orchestrator owns `docs/superpowers/plans/storage-progress.md`. Each stream writes only `docs/superpowers/plans/progress/<stream>.md` (plan/done/next, agent/worktree, blockers); ≤15-line final report.
- **Ownership:** §2 matrix. Need a change in a file you don't own → note it in your progress file, local extension in your own files, orchestrator routes it. W1 types frozen after W1 merges; changes = ICR 018 addendum via orchestrator.
- **No AppKit** in `MonitorDiskTools`, `MonitorRuntime`, `MonitorLive`. AppKit needs → `@Sendable` closures in `StoragePlatform` (W1), built by `StorageActionsLive` (W3b).
- **Concurrency:** ARCH §4 bans (`docs/ARCHITECTURE.md:216`). Locks: `Mutex` (Synchronization; allowed now that the target is macOS 15 — W1 updates the "`Mutex` is macOS 15+, so not used" note at `docs/ARCHITECTURE.md:205`) or `OSAllocatedUnfairLock` (precedent `Sources/MonitorScreens/Shell/InMemoryDefaults.swift:13`). **Never add `@unchecked`.**
- **`@unchecked` gate:** `scripts/ci.sh:50-56` is green on dev (Mixer fixed in f08eb24). Any hit = failure. Quote the ci output.
- **Logging:** `Logger(subsystem: "dev.telltale", category: "storage")` (subsystem precedent `Sources/MonitorRuntime/LivePipeline.swift:41`).
- **Tests:** only tests that catch a named bug (listed per stream). Rerun only failed suites + suites of touched sources. HW smoke suites (`TELLTALE_HW_TESTS=1`, precedent `Tests/MonitorSensorsTests/VolumeSmokeTests.swift:6`) never in `ci.sh` args (`scripts/test.sh:35` fails on zero tests).
- **Gate per stream:** `scripts/ci.sh <your suites>`; perf numbers advisory, reported not tuned.
- **Snapshots:** record with `TELLTALE_RECORD=1 scripts/test.sh <Suite>` (`Sources/MonitorSnapshotTesting/AssertSnapshot.swift:20`); view every new/changed PNG before committing; `ci.sh` is strict (`scripts/ci.sh:8`).
- **Commits:** prefix per stream; trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- **Review:** after each wave, Codex via T3 `delegate_task` (`gpt-6-astra`; `xhigh` for W2c and W3b, `high` otherwise). Max 2 rounds.

---

## 1. Waves

```
W1 foundation (1 stream) ─┬─ W2a scanner+cache+probe ─┐
                          ├─ W2b classifier ──────────┼─ W3a StorageModel ─┐
                          ├─ W2c cleaner+undo+in-use ─┤  W3b runtime+live ─┼─ W4a page+SpaceMap ─┐
                          └─ W2d UIKit ───────────────┘  W3c mocks ────────┘  W4b Cleanup ────────┼─ W4-final
                                                                              W4c sidebar/popover/catalog ┘
```

| Wave | Streams (≤4 concurrent) | Hard deps |
|---|---|---|
| W1 | W1 | — |
| W2 | W2a, W2b, W2c, W2d | W1 merged |
| W3 | W3a, W3b, W3c | W3a/W3c: W1 only (may start when a W2 slot frees). W3b: W2a–c **and W2d** merged (it edits a UIKit file, §2) |
| W4 | W4a, W4b, W4c → W4-final (W4a owner) | W3 + W2d merged |

---

## 2. Ownership matrix (one owner per file per wave)

| Wave | Stream | Owns |
|---|---|---|
| W1 | W1 | `docs/icr/018-W1-storage-page.md`, `SPEC.md`, `docs/ARCHITECTURE.md`, `docs/design/DESIGN.md`, `docs/RULINGS.md`, `Config/**`, `.gitignore`, `project.yml`, `scripts/{install,ci}.sh`, `Package.swift`, `Sources/MonitorModel/Storage/**` (new), `Sources/MonitorModel/Services/Navigation.swift`, `Sources/MonitorModel/Sensors/Sampling.swift`, `Sources/MonitorScreens/Shell/{DashboardRoot,PageHeader,Sidebar}.swift`, `Sources/MonitorScreens/Pages/Storage/StoragePage.swift` (placeholder), `Sources/MonitorUIKit/Tokens/TTIcon.swift`, `Sources/MonitorUIKit/Gallery/GalleryPopover.swift`, `Sources/MonitorDiskTools/{DiskTools,Support/**}`, `Tests/MonitorModelTests/{UIVisibilityTests,StorageTree*,StorageOverlay*,Reclaim*}.swift`, `Tests/MonitorDiskToolsTests/{Support/**,Fixtures/.gitkeep,SafePathTests.swift}`, goldens `shell-sidebar-calm`, `component-icons`, `component-sidebar` |
| W2 | W2a scan | `Sources/MonitorDiskTools/Scan/**`, `Sources/MonitorDiskTools/Cache/**`, `Sources/telltale-probe/**`, `Tests/MonitorDiskToolsTests/{Scanner,BulkParser,BulkListerSmoke,ScanCache,PrivateSize}*`, `Tests/MonitorDiskToolsTests/Fixtures/bulk/**` |
| W2 | W2b classify | `Sources/MonitorDiskTools/Classify/**`, `Tests/MonitorDiskToolsTests/{Classifier,BundleID,InstalledApps,BuildDir}*` |
| W2 | W2c clean | `Sources/MonitorDiskTools/Clean/**`, `Tests/MonitorDiskToolsTests/{Cleaner,Staging,Undo,InUse,Guardrail,Denylist}*` |
| W2 | W2d UIKit | `Sources/MonitorUIKit/**` **except** `Tokens/TTIcon.swift`, `Gallery/GalleryPopover.swift`, `Environment/EnvironmentValues+Telltale.swift`; `Tests/MonitorUIKitTests/**` (+ `__Snapshots__`) |
| W3 | W3a model | `Sources/MonitorLive/Storage/**`, `Tests/MonitorLiveTests/Storage*` |
| W3 | W3b runtime | `Sources/MonitorRuntime/{TelltaleRuntime,LivePipeline,StoragePipeline}.swift`, `Sources/MonitorDiskTools/Engine/**`, `Sources/MonitorScreens/Shell/{ShellEnvironment,StorageActionsLive,SettingsStore}.swift`, `Sources/MonitorUIKit/Environment/EnvironmentValues+Telltale.swift`, `App/Sources/Composition/AppEnvironment.swift`, `App/Sources/Dashboard/DashboardWindowController.swift`, `Tests/MonitorRuntimeTests/Storage*`, `Tests/MonitorScreensTests/ShellStorage*` |
| W3 | W3c mocks | `Sources/MonitorMocks/{MockStorageState,MockDataProvider,ActionLog}.swift`, `Sources/MonitorRuntime/MockPipeline.swift`, `Tests/MonitorMocksTests/Storage*` |
| W4 | W4a page | `Sources/MonitorScreens/Pages/Storage/{StoragePage,StorageChrome,SpaceMapView,StorageStates}.swift` |
| W4 | W4b cleanup | `Sources/MonitorScreens/Pages/Storage/{CleanupView,CleanupLines,CleanConfirm,CleanToast}.swift`, `Tests/MonitorScreensTests/StorageCleanup*` |
| W4 | W4c shell | `Sources/MonitorScreens/Shell/{Sidebar,ScreenCatalog}.swift`, `Sources/MonitorScreens/Popover/{PopoverRoot,PopoverModel,PopoverRowView,FlyoutModel,FlyoutView}.swift`, `Tests/MonitorScreensTests/{ShellComposition,Popover,Flyout}Tests.swift`, `__Snapshots__/popover-*`, `__Snapshots__/flyout-*` |
| W4 | W4-final (W4a) | `Tests/MonitorScreensTests/StorageSnapshotTests.swift`, `__Snapshots__/storage-*` |

---

## 3. Interfaces fixed in W1

All in `Sources/MonitorModel/Storage/`, `public`, `Sendable`, explicit inits. W1 may add members, not rename.

### 3.1 Tree, builder, overlay, reclaim

```swift
public typealias StorageNodeID = Int32
public struct StorageNodeFlags: OptionSet { directory, package, restricted, dataless, skippedMount, hidden, sealed, symlink }   // UInt16
public struct StorageMarker: OptionSet {   // UInt32; set by W2a, read by W2b
  git, packageJSON, packageSwift, cargoToml, podfile, gradle, cmakeLists, cachedirTag, cmakeCache,
  swiftpmWorkspaceState, npmLock, pnpmModules, yarnState, podsManifest }
public struct FileIdentity: Hashable, Codable { dev: Int32; ino: UInt64; isDirectory: Bool }

public final class StorageTree: Sendable {            // immutable; swap = one assignment; views compare `version`
  let version: UInt64, root: ScanRoot, volumeUUID: UUID?, dev: Int32, scanDate: Date, lastEventId: UInt64
  // SoA, index = StorageNodeID; parent < child; children contiguous [firstChild, +childCount)
  parent, firstChild, childCount: [Int32]; allocBytes: [UInt64] /*rolled up; restricted contributes 0*/
  smallBytes: [UInt64]; smallCount: [UInt32]; fileID: [UInt64]
  mtime, subtreeMaxMtime, addedTime: [Int64]; flags: [StorageNodeFlags]; markerMask: [StorageMarker]
  nameOffset: [UInt32]; nameLength: [UInt16]; names: [UInt8]
  childOrder: [Int32]     // same ranges as children, size desc, ties by name; IDs stay stable
  childPrefix: [UInt64]   // prefix sums over childOrder — only for "N smaller items" remainder totals
  linkGroups: [HardLinkGroup]
  func name/path/size(_:) ; sortedChildren(_:) -> ArraySlice<Int32>; isAncestor(_:of:); lookup(path:); depth(_:)
  func cutoff(_ node:, minFraction:) -> Int  // binary search on descending child SIZES for first child < fraction × parent
  func remainderBytes(_ node:, from cut: Int) -> UInt64   // via childPrefix
}
/// One per (dev, ino) with linkcount > 1 seen during the scan (kept files and folded small files alike).
public struct HardLinkGroup: Sendable { identity: FileIdentity; linkCount: UInt16; bytes: UInt64
  occurrences: [StorageNodeID] /* file node if kept, else containing dir node; one entry per observed link */ }

public struct StorageTreeBuilder: Sendable {           // value type; W2a holds it in Mutex<StorageTreeBuilder>
  init(root: ScanRoot, dev: Int32, volumeUUID: UUID?)
  mutating func appendChildren(of: StorageNodeID, _ records: [NodeRecord]) -> Range<Int32>
  mutating func setDirFacts(_ node:, markers: StorageMarker, flags: StorageNodeFlags)   // after allocation, once listed
  mutating func setRestricted(_ node:)
  mutating func addSmall(_ dir:, bytes:, count:, maxMtime: Int64)   // folded files feed subtreeMaxMtime
  mutating func addLink(_ identity:, linkCount:, bytes:, occurrence: StorageNodeID)
  func snapshot() -> StorageTree                       // non-consuming, for .partial (copy; advisory cost)
  consuming func finalize(scanDate:, lastEventId:) -> StorageTree   // reverse-pass rollup; link bytes credited once at lowest-depth occurrence; childOrder; prefix sums
}
public struct NodeRecord: Sendable { name: [UInt8]; flags; allocBytes; fileID; mtime; addedTime }

/// Mutations after cleaning/undo, applied over an immutable tree (no tree rebuild).
public struct StorageTreeOverlay: Sendable, Codable, Equatable {
  let treeVersion: UInt64; private(set) var version: UInt64
  removed: Set<StorageNodeID>            // node and its subtree gone
  sizeDelta: [StorageNodeID: Int64]      // keep-parent partial removals, restores; propagated to ancestors on write
  restored: [RestoredEntry]              // { parent: StorageNodeID, name: String, bytes: UInt64, itemID: Int32 } (e.g. "name (restored)")
  mutating func remove(_ node:, in tree:); mutating func shrink(_ node:, by:, in tree:); mutating func restore(_ entry:, originalNode:, in tree:)
  func size(_ node:, in tree:) -> UInt64?     // saturating; nil if removed/restricted
  func isRemoved(_ node:, in tree:) -> Bool   // node or any ancestor removed
}

/// Bytes freed by deleting a selection, with hard links counted over the UNION (not per item).
public struct ReclaimAccumulator: Sendable {
  init(items: [CleanupItem], tree: StorageTree)
  mutating func insert(_ id: Int32); mutating func remove(_ id: Int32)    // O(item's link groups)
  var bytes: UInt64 { get }   // Σ item.privateBytesExcludingLinks + Σ group.bytes for groups whose linkCount == occurrences inside the union; saturating
  var provenance: SizeProvenance { get }   // worst of selected items
}
```

### 3.2 Scan, cleanup, clean, policy, actions

```swift
public enum ScanRoot: Hashable, Codable { case home(String), folder(String), volume(path: String, name: String); var path; var allowsCleanup /*home only*/ }
public struct ScanProgress: Equatable { files: Int; bytes: UInt64; currentPath: String }
public enum ScanFailure: Equatable, Error { case volumeRemoved, rootUnreadable(String), cancelled, io(String) }
public enum ScanEvent { case progress(ScanProgress), partial(StorageTree), finished(StorageTree),
  classified(CleanupSet) /*after classify; again after ownership resolution and private sizes*/, failed(ScanFailure) }

public enum CleanupCategory: String, CaseIterable, Codable { case userCaches, leftovers, largeOld, developer, trash }
public enum SafetyTier: String, Codable { case safe, review }
public enum DeleteMode: String, Codable { case remove, trash, evict, simctl, none }
public enum SizeProvenance: String, Codable, Comparable { case exact, estimate, unavailable }   // estimate = allocated bytes; clone sets: private is a lower bound
public struct OwnerApp: Hashable, Codable { bundleID: String; name: String; appPath: String? }
public struct CleanupItem: Identifiable, Equatable {
  id: Int32; parentID: Int32?; nodeID: StorageNodeID?; path: String; name: String
  category; tier; mode; identity: FileIdentity?; allocBytes: UInt64
  privateBytesExcludingLinks: UInt64?; linkGroupIndices: [Int32]; sizeProvenance: SizeProvenance
  lastUsed: Date?; owner: OwnerApp?; runningApp: Bool; keepParent: Bool; ignored: Bool; note: String? }
public struct CleanupSet: Equatable { treeVersion: UInt64; items: [CleanupItem]; ownershipResolved: Bool; privateSizesFinal: Bool; trashBytes: UInt64? }
public struct ClassifyOptions: Equatable { now: Date; largeBytes: UInt64; oldBytes: UInt64; oldAge: TimeInterval; ignoredPaths: Set<String> }

public enum DenyReason: Equatable, Codable { case anchor /*is or contains*/, protected /*is, contains or inside*/, outsideRoot,
  removeOutsideHome, unverifiable /*identity chain could not be established*/ }
public enum SkipReason: Equatable, Codable { case denied(DenyReason), inUse, changedSinceScan, notPermitted, noTrash,
  stagingOtherVolume, vanished, rollbackCollision, cancelled, failed(String) }
public struct CleanItemOutcome: Equatable { itemID: Int32; detachedBytes: UInt64; removedNodes: [StorageNodeID]
  committedChildren: Int; skippedChildren: Int; partial: Bool; skip: SkipReason?; trashedTo: String? }
public enum CleanEvent { case item(CleanItemOutcome), freed(UInt64), restored(itemID: Int32, finalPath: String), finished(CleanReport) }
public struct CleanReport: Equatable { freedBytes, trashedBytes, evictedBytes: UInt64; outcomes: [CleanItemOutcome]; cancelled: Bool
  stagingLeftovers: Int; undo: UndoRecord? }
public struct UndoRecord: Equatable, Codable, Identifiable { id: UUID; date: Date; entries: [UndoEntry] }
public struct UndoEntry: Equatable, Codable { itemID: Int32; nodeID: StorageNodeID?; originalPath: String; trashPath: String; identity: FileIdentity; trashParentPath: String; trashParentIdentity: FileIdentity }
public struct StorageSummary: Equatable, Codable { root: ScanRoot; scanDate: Date; reclaimableBytes: UInt64?; provenance: SizeProvenance; trashBytes: UInt64? }

/// Precomputed at scan finish/clean time by the engine; lets the UI disable "Move to Trash" without DiskTools.
public struct StoragePolicy: Equatable { func denyReason(trash node: StorageNodeID, in tree: StorageTree) -> DenyReason? ; static let none }

public struct StoragePlatform: Sendable {     // AppKit, injected
  runningBundleIDs: @Sendable () async -> Set<String>
  appPaths: @Sendable (_ bundleID: String) async -> [String]          // urlsForApplications(withBundleIdentifier:)
  willUnmount: @Sendable () -> AsyncStream<String>                    // NSWorkspace.willUnmountNotification volume paths
  static let none }

public struct StorageActions: Sendable {     // shape of ProcessActions (Sources/MonitorModel/Services/ProcessActions.swift:38-61)
  scan: @MainActor @Sendable (ScanRoot, ClassifyOptions) -> AsyncStream<ScanEvent>
  cancelScan: @MainActor @Sendable () -> Void
  loadCached: @MainActor @Sendable (ScanRoot, ClassifyOptions) async -> (StorageTree, StorageTreeOverlay, CleanupSet)?
  loadSummary: @MainActor @Sendable () async -> StorageSummary?           // ~ root summary only (sidebar)
  reclassify: @MainActor @Sendable (ClassifyOptions) async -> CleanupSet?
  policy: @MainActor @Sendable () -> StoragePolicy                         // canTrash / deny reason for Space Map menus
  checkInUse: @MainActor @Sendable ([CleanupItem]) async -> Set<Int32>
  clean: @MainActor @Sendable ([CleanupItem]) -> AsyncStream<CleanEvent>
  cancelClean: @MainActor @Sendable () -> Void
  undo: @MainActor @Sendable (UndoRecord) -> AsyncStream<CleanEvent>
  emptyTrash: @MainActor @Sendable () -> AsyncStream<CleanEvent>
  release: @MainActor @Sendable () -> Void                                 // window closed: drop engine state
  availableRoots: @MainActor @Sendable () -> [ScanRoot]
  hasFullDiskAccess: @MainActor @Sendable () async -> Bool
  ignore, unignore, revealInFinder: @MainActor @Sendable (String) -> Void; openFDASettings: @MainActor @Sendable () -> Void
  static let noop }
```

### 3.3 DiskTools shared support (W1, frozen in W2)

`Support/FileDescriptor.swift` (`~Copyable` fd owner, close in deinit; only the owning worker closes). `Support/SafePath.swift`:
- `RelativePath(validating:)` rejects `..`, `.`, empty components, NUL, absolute input; confinement by component compare, never string prefix (`/Users/a` vs `/Users/ab`).
- `TrustedRoot(path:)` opens the root once (`O_DIRECTORY|O_NOFOLLOW`), runs capability probes once per process: `O_RESOLVE_BENEATH` (open `..` from a temp dir must fail `ENOTCAPABLE`), `O_NOFOLLOW_ANY` (mid-path symlink must fail `ELOOP`). Probe passes → `openat(root, rel, flags|O_RESOLVE_BENEATH|O_NOFOLLOW_ANY)`; fails → component walk `openat(O_NOFOLLOW|O_DIRECTORY)` per component. Both return the chain `[FileIdentity]` of every opened ancestor (walk always done when a chain is requested).
Entry points W2 streams implement (W3b composes in `Engine/StorageEngine.swift`):

| Stream | Entry point |
|---|---|
| W2a | `protocol DirectoryLister: Sendable { func list(_ dir: borrowing FileDescriptor, path: String, maxEntries: Int) throws(ListError) -> ListBatch }` (bounded batches); `BulkLister`, `InMemoryLister`, `FileManagerLister`; `Scanner(lister:, threads:).scan(root:, unmount: AsyncStream<String>) -> AsyncStream<ScanEvent>`, `cancel()`; `ScanCache(directory:)` `.save(tree)`, `.saveOverlay(_:)`, `.load(root:, volumeUUID:) -> (StorageTree, StorageTreeOverlay)?`; `PrivateSizer` (bulk walk of candidate subtrees); `FullDiskAccessProbe.check(home:)`; `ScanRoots.available()` |
| W2b | `InstalledAppSet.build(home:, mdfind:)`; `SpotlightLastUsed.query(root:, minBytes:)`; `Classifier(home:, dataDirectories:, git:, devTools:, isUbiquitous:)` `.classify(tree:, installed:, lastUsed:, options:) -> ClassifyResult { set: CleanupSet; unresolvedBundleIDs: Set<String> }`; `.resolve(_ result:, found: [String: [String]]) -> CleanupSet` |
| W2c | `Cleaner(context: CleanContext)` `.clean(_ items:, tree:, overlay:) -> AsyncStream<CleanEvent>`, `.cancel()`, `.emptyTrash()`; `CleanContext { home, permittedRoot, stagingDir, dataDirectories, trash: TrashMover, deleter: Deleter, log }`; `Denylist.build(home:, scanRoot:, dataDirectories:) -> Denylist`; `Staging(dir:)` `.sweep() -> SweepReport`; `UndoStore(file:)` `.append/.prune/.restore(_:)`; `InUseChecker(processes:).inUse(_:)` |

---

## 4. Streams

### W1 — foundation (single stream, sequential, commit per step)

Prefixes `docs(storage):`, `build(signing):`, `model:`, `build(disktools):`.

- [ ] **1.1 ICR 018** `docs/icr/018-W1-storage-page.md` (format of `docs/icr/009-W5b-disk-session-totals.md`): `DashboardPage.storage` + §3 types; row 18 in ARCH §11 table (`docs/ARCHITECTURE.md:1423-1442`).
- [ ] **1.2 Docs** (spec §3.6 as corrected in §7): SPEC ruling "cleanup in v1" (`SPEC.md:10-41`), Categories `:52-53`, Data sources `:55` (getattrlistbulk incl. PRIVATESIZE, MDQuery/mdfind, FDA probe, proc_pidinfo vnode paths), Actions `:96-97`, artboards `:7` ("Storage: rendered, no artboard"). ARCH: §2 tree + graph (`:59-157`), rule `:159` += `MonitorDiskTools`; §4 table (`:201-210`) scanner pool row + `Mutex` note `:205`; §5.10/5.11 (`:1108`, `:1164`); §7 (`:1327`) scan memory; §8 (`:1367`); §11 row 18; fix stale ProcessActionsLive path (`:74`). Threat model paragraph (§0) into ARCH §5.10. DESIGN: §1.4 (`:237`) storage glyph; §2.28 (`:514`) "N smaller items"; §2.29 (`:539`) table checkbox; §3.12 toast (`:999`) Show / Empty Trash / Undo rules (W2d/W4b); §3.1 (`:595`) "Free up space…" copy + placement (Disk flyout or Disk row; W4c follows); **new §3.17 Storage** after §3.16 Overlay (`:1152`); §5.8 (`:1333`) `Scanned {n} {unit} ago` row; "≈" + clone lower-bound tooltip copy. No Finder "Put Back" claim until W4-final checks it. RULINGS: plan decisions (ICR 018, childOrder, overlay sidecar, own-data exclusion, threat model).
- [ ] **1.3 Signing** (no Team ID): `Config/Signing.xcconfig` (`CODE_SIGN_IDENTITY = -`, `CODE_SIGN_STYLE = Manual`, last line `#include? "Local.xcconfig"`), `Config/Local.xcconfig.example` (`DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY = Apple Development`, `CODE_SIGN_STYLE = Automatic`), `.gitignore` += `Config/Local.xcconfig`; `project.yml` delete `:11-12`, add `configFiles: {Debug: Config/Signing.xcconfig, Release: Config/Signing.xcconfig}` to target `Warden` (`:23`). `scripts/install.sh:42-45`: `Config/Local.xcconfig` present → keep xcodebuild's signature (`codesign -v`, print identity); else unchanged.
  Verify: `scripts/build.sh` → `BUILD SUCCEEDED`; `codesign -dv` → `adhoc`; temp-copy example → `xcodebuild -showBuildSettings | grep CODE_SIGN_` → Apple Development/Automatic; delete copy. Not verified: a real cert build.
- [ ] **1.4 Package:** target `MonitorDiskTools` (deps `MonitorModel`), test target `MonitorDiskToolsTests` (`resources: [.copy("Fixtures")]`), `MonitorRuntime` deps += it (`Package.swift:74-79`), `telltale-probe` deps += it (`:84-87`). `DiskTools.swift`, `Support/{FileDescriptor,SafePath}.swift` (§3.3), `Tests/MonitorDiskToolsTests/Support/TreeFixture.swift` (DSL over `StorageTreeBuilder`). `ci.sh` new grep: `import MonitorDiskTools` forbidden in `Sources/{MonitorLive,MonitorScreens,MonitorUIKit}` and `App/` (ARCH `:159` is doc-only today).
- [ ] **1.5 `model:` commit:** §3.1–3.2 types with real `StorageTreeBuilder`, `StorageTreeOverlay`, `ReclaimAccumulator`, `StoragePolicy` data shape. `DashboardPage.storage` after `.disk` (`Navigation.swift:4`), title `:8`, section `.system` `:24-26`. Switches: `Sampling.swift:63` (`.storage` → `.none`); `PageHeader.swift:114`/`:144` (page-provided nil); `DashboardRoot.swift:49` (placeholder `StoragePage` = `TTEmptyState`, replaced by W4a); `Sidebar.swift:53` (`case .disk, .storage:` free space; W4c adds reclaimable); `TTIcon.swift:7-9` new `storage` case, svg switch `:13`, `page()` `:99`. `GalleryPopover.swift:45-47` `.storage` value. `UIVisibilityTests.swift:7-18` `(.storage, [])`. No edit: `LaunchOptions.swift:65`, `telltale-probe/Options.swift:98`, `TTSidebarItem.swift:26`, `ScreenCatalog.swift:43`, `ShellSnapshotTests.swift:23`.
  Re-record (view diffs; only the new row/icon may change): `shell-sidebar-calm`, `component-icons`, `component-sidebar`.
- Tests (W1):
  - `StorageTreeTests`: rollup with grandchildren committed in a later batch — bug: out-of-order batches undercount. Restricted child excluded, `size == nil` — bug: 0 B shown as real. `childOrder` desc, ties by name, IDs unchanged — bug: hover/cache hits wrong node. `cutoff` on `[90,5,3,2]` at 4 % → 2 kept, remainder 5 — bug: off-by-one at boundary. Folded small file mtime raises `subtreeMaxMtime` — bug: project with only small fresh files looks stale. `lookup` with trailing slash / missing component → nil.
  - `StorageOverlayTests`: remove node → ancestors shrink, descendants `isRemoved`; keep-parent partial shrink keeps parent; restore to original path re-adds bytes; restore as "(restored)" adds entry under parent; saturating at 0 — bug: negative/wrapped totals after clean+undo.
  - `ReclaimTests`: link outside scan (linkCount 2, 1 observed) never counted; joint selection of two items each holding one link of a 2-link group counts once only when both selected; same-dir links (2 occurrences in one dir) counted once — bug: hard-link double count or phantom reclaim.
  - `SafePathTests` (temp dir): `..`/`.`/empty/NUL/absolute rejected; `/x/a` root rejects `/x/ab/f`; mid-path symlink refused in both probe and walk mode (walk forced by a test seam) — bug: escape via spelling/symlink.
  - Break-check: flip rollup order once, confirm red, revert.
- Gate: `scripts/ci.sh StorageTreeTests StorageOverlayTests ReclaimTests SafePathTests UIVisibilityTests ShellSnapshotTests ComponentSnapshotTests ShellScreenCatalogTests`.

### W2a — scanner, arena fill, cache, probe

Prefix `feat(storage-scan):`. Files `Scan/{BulkAttrParser,BulkLister,FileManagerLister,InMemoryLister,DirectoryLister,Scanner,WorkQueue,HardLinkSet,MarkerTable,PrivateSizer,FullDiskAccessProbe,ScanRoots,VolumeWatch}.swift`, `Cache/ScanCache.swift`, `telltale-probe/**`.

- [ ] `BulkAttrParser`: per-entry `ATTR_CMN_RETURNED_ATTRS` mask walk (spikes §6: dirs omit file attrs); attrs = spec §5.1 + `ATTR_CMN_FILEID` + `ATTR_CMNEXT_PRIVATESIZE` via `forkattr` + `FSOPT_ATTR_CMN_EXTENDED` (spikes §3); read PRIVATESIZE only when its returned bit is set. All unsafe pointer code in this file.
- [ ] `BulkLister` 256 KB buffer; returns bounded batches (`maxEntries`) so cancel is checked between `getattrlistbulk` calls.
- [ ] `Scanner`: `min(8, hw.perflevel0.physicalcpu)` `Thread`s (spikes §6: 8 threads ≈ 5× one); `.userInitiated`; `WorkQueue` LIFO under `Mutex`, `queued + inFlight` counters, condition wake; done when both 0; cancel flag per pop and between batches; per-thread `setiopolicy_np(…MATERIALIZE_DATALESS_FILES_OFF)` (spikes §8); walk rules spec §5.2; keep rules §5.3 (dirs, files ≥ 1 MB, direct children of `~/Library/{Application Support,Caches,Containers,Group Containers,Preferences,Saved Application State,HTTPStorages,WebKit,Logs}`); `setDirFacts` after listing; `addSmall` with max mtime; every linkcount > 1 file → `addLink` (dedupe via `HardLinkSet` 16 shards); builder in `Mutex<StorageTreeBuilder>`; `.partial` from `snapshot()` at 3 Hz; `.progress` ≤ 10 Hz. Fds closed only by the worker that opened them.
- [ ] `VolumeWatch`: `platform.willUnmount` stream (ordinary eject → cancel promptly so fds close before unmount), `DispatchSource` `.revoke` on root fd, `ENXIO/EIO/ENODEV` from listing (forced removal) → `.failed(.volumeRemoved)`.
- [ ] `ScanCache`: header (magic, schema, root, volume UUID, date, `FSEventsGetCurrentEventId`, counts) + raw arrays → `dataDirectory/storage-scan-<fnv(uuid+root)>.bin`; temp + `rename`; `mmap` read; mismatch/torn → nil + delete. Overlay sidecar `…​.overlay.json` (atomic). Never written for partial/cancelled/failed scans.
- [ ] `PrivateSizer`: bulk walk of candidate subtrees requesting PRIVATESIZE; sums non-link files into `privateBytesExcludingLinks`; links → group indices; provenance `.exact`, or `.estimate` (alloc) when the bit isn't returned; utility queue.
- [ ] `FullDiskAccessProbe` (`~/Library/Safari` `EPERM` → no FDA), `ScanRoots.available()` (`getfsstat`, drop `MNT_DONTBROWSE`/`MNT_SNAPSHOT`, Data volume → "Macintosh HD").
- [ ] `telltale-probe --scan <root> [--threads N]` (`Options.swift:7` enum, `:72` parse): entries, nodes, wall, RSS, entries/s.
- [ ] Bulk fixtures via `TELLTALE_RECORD_BULK=1` smoke run → `Fixtures/bulk/*.bin` + expected JSON.
- Tests (`InMemoryLister` unless noted):
  - `ScannerTests` random trees (50 seeds), 8 threads + random latency == naive sums; parent < child; contiguous — bug: concurrent commits interleave/lose children.
  - delayed root listing (root lister blocks 200 ms) → no premature finish — bug: done detected while `queued == 0` but root in flight.
  - cancel with all 8 workers inside listings → stream ends `.failed(.cancelled)`, every opened fd closed (lister counts), no cache — bug: hang / fd leak / partial cached.
  - hard links: 2 links at depths 4 and 2 → credited once at depth 2, identical across 20 runs — bug: timing-dependent sizes.
  - small files fold; `~/Library/Preferences/*.plist` kept — bug: leftovers can't see plists.
  - markers + `subtreeMaxMtime` ignores fresh `node_modules` — bug: stale project looks fresh.
  - `EACCES` → restricted, scan continues; dataless dir never listed; mount/trigger dir never listed; `.app` leaf with size — bugs: abort / iCloud download / walk into `/Volumes` / package internals shown.
  - unmount: injected `willUnmount` path → `.failed(.volumeRemoved)`, no cache (ordinary eject); lister throws `ENXIO` → same (forced removal).
  - `BulkParserTests`: recorded dir→file, file→dir, error entry, PRIVATESIZE present/absent — bug: fixed-layout misread.
  - `ScanCacheTests`: round-trip arrays + overlay; other root / UUID / schema+1 / truncated → nil — bug: wrong or torn cache loaded.
  - `BulkListerSmokeTests` (HW-gated): real bulk == `FileManagerLister` on temp tree; symlink not followed; clone pair private sizes (spikes §3 numbers).
- Perf (advisory, report): `telltale-probe --scan ~`. Spikes §6 measured ~125k entries/s warm (8 threads) → 1M entries ≈ 8 s vs spec target 5 s; full home 6.25M ≈ 50 s. Cache load ~300k nodes < 100 ms.
- Gate: `scripts/ci.sh ScannerTests BulkParserTests ScanCacheTests`.

### W2b — classifier, installed apps, Spotlight

Prefix `feat(storage-classify):`. Files `Classify/{BundleID,InstalledAppSet,SpotlightLastUsed,Classifier,CategoryRules,BuildDirRules,DevToolProbe,GitTracking}.swift`.

- [ ] `BundleID.normalize` (spec §6.1), `isAppleOwned`.
- [ ] `InstalledAppSet` (§6.2) without the NSWorkspace step; `owns(id)` rules; `<TeamID>.<word>` never flagged.
- [ ] Two-stage ownership: `classify` returns candidate leftovers whose IDs aren't owned as `unresolvedBundleIDs` (items marked unresolved, not yet in Leftovers); engine resolves via `platform.appPaths` (async); `resolve` drops owned ones and finalizes (`ownershipResolved = true`).
- [ ] `SpotlightLastUsed`: one scoped `MDQuery`.
- [ ] `Classifier` (§6.3): priority Developer > User Caches > Leftovers > Large & Old; largest matching subtree; nested de-dupe; exclusions: Apple-owned, system cache list, own data dirs (`dev.telltale*`, `dev.warden*`, `dev.telltale-dev` — `scripts/run.sh:16`) and anything that is/contains/is inside an injected `dataDirectories` entry. Large & Old: last used = max(mtime, addedTime, Spotlight); `isUbiquitous(url)` (injected; live = `FileManager.isUbiquitousItem`) → `.evict`, else `.trash`. Dev rows per spec incl. `DevToolProbe.xcodeSelectOK`, Docker `.none` + note, build dirs with `GitTracking` (`git ls-files -z -- <dir>`, 5 s timeout → treated as tracked). Ignored paths → `ignored = true` (kept, UI filters). Items carry `linkGroupIndices` + provenance from tree/`PrivateSizer`.
- Tests:
  - `BundleIDTests` table (spec §8 IDs) — bug: Apple group containers flagged.
  - ownership prefix/suffix/vendor; `com.foo` vs `com.foobar`; TeamID-only — bug: installed app's data offered.
  - app found **only** via injected `appPaths` lookup → not a leftover after `resolve` — bug: helper-only/odd-location apps lose data.
  - `InstalledAppsTests`: hits under `~/.Trash`, `/Volumes`, AppTranslocation dropped; nested `.appex` id added.
  - leftovers 89 d vs 91 d (injected `now`) — bug: off-by-one age gate.
  - own data exclusion: `dev.warden`, `dev.telltale-dev/<wt>`, injected staging dir never items; `com.apple.dt.Xcode` allowed — bug: deleting our store/staging.
  - Large & Old boundaries (500 MB exact, 50 MB + 6 mo), recent `addedTime` wins, scope exclusions; ubiquitous → `.evict`, non-ubiquitous → `.trash` — bug: trashing iCloud file instead of evicting.
  - build dirs: `.git` ancestor + marker + 30 d + no tracked files; `~/.cargo`, `~/Library` excluded — bug: tracked `build/` deleted.
  - priority + nesting: `node_modules` inside leftover dir appears once — bug: double count/delete.
  - ignored item round-trip: ignored → `ignored == true` and still present; removed from `ignoredPaths` → `false` — bug: unignore impossible.
  - DeviceSupport keeps newest per platform.
  - Break-check: flip one ownership rule, confirm red, revert.
- Perf (advisory): classify 180k nodes < 50 ms.
- Gate: `scripts/ci.sh ClassifierTests BundleIDTests InstalledAppsTests BuildDirTests`.

### W2c — cleaner, guardrails, staging journal, undo, in-use

Prefix `feat(storage-clean):`. Files `Clean/{Cleaner,Denylist,Staging,DeleteWorker,TrashMover,Evictor,SimctlRunner,UndoStore,InUseChecker,ProcessPathSource}.swift`.

- [ ] **Denylist** (live, never from scan data). Anchors: `/`, `~`, `~/Library`, every direct child of `~/Library`, `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/private`, `/opt/homebrew`, `/usr/local`, scan root — target must not **be or contain** one. Protected subtrees: `~/Library/Keychains`, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Library/Mail`, `~/Library/Application Support/MobileSync`, own data dirs (`dev.warden`, `dev.telltale`, `dev.telltale-dev`, injected `dataDirectories`) — target must not **be, contain, or be inside** one. At clean time: per denylisted path compute its live ancestor chain (component walk from `/`, `fstatat(AT_SYMLINK_NOFOLLOW)` on the last component; `ENOENT` → chain of existing ancestors only). Per target: `TrustedRoot` open yields the target's live chain below the root, prefixed with the root's own live ancestor chain (component walk from `/`, computed once per `TrustedRoot`) — so a scan root inside a protected subtree (e.g. `~/Library/Mail/V10`) still sees `~/Library/Mail`. Test: scan root `~/Library/Mail/V10`-equivalent under the injected permitted root, trash a descendant → denied. is = target identity ∈ denylisted identities; contains = target identity ∈ chain(D) for some D; inside = some identity of target's chain ∈ protected identities. Chain not establishable → `.denied(.unverifiable)`.
- [ ] **Policy:** remove mode refused outside `~`; any target outside `permittedRoot` refused. `StoragePolicy` snapshot (anchor/protected node ids in the tree) exported for UI; backend always re-checks live.
- [ ] **Staging journal** (remove mode): `staging/pending/` and `staging/commit/` (0700, created on demand). Per item: write sidecar `pending/<uuid>.json` {original parent path, parent identity, name, item identity}; `renameatx_np(parentFd, name, pendingFd, uuid, RENAME_EXCL|RENAME_NOFOLLOW_ANY)`; `fstatat` identity vs scan; mismatch → rename back with `RENAME_EXCL` (collision → leave in pending, `.rollbackCollision`); match → `renameatx_np(pendingFd, uuid, commitFd, uuid, RENAME_EXCL)` (same volume, atomic), delete sidecar. Worker deletes **only** `commit/`. Staging not on item's volume → `.stagingOtherVolume` (no direct `removefile`: it rebuilds paths via `F_GETPATH`). All renames take (parent fd, leaf name), so symlink traversal can't occur even if a flag were ignored.
- [ ] **Keep-parent:** at clean time list the parent live (fd-relative), detach each child individually through the journal; outcome aggregates `detachedBytes`, `committedChildren`, `skippedChildren`, `partial`, `removedNodes` (children that are tree nodes).
- [ ] **Launch sweep** (`Staging.sweep`): `commit/*` → delete; `pending/*` → reopen original parent via `TrustedRoot`, verify parent identity, rename back (`RENAME_EXCL`); else leave and report (`stagingLeftovers`); never delete pending; orphan sidecars removed.
- [ ] **DeleteWorker:** ≤ 4 parallel `removefileat(commitFd, name, state, REMOVEFILE_RECURSIVE|REMOVEFILE_RECURSIVE_SLIM)` with **error callback only** (no confirm/status callbacks — SLIM + those → `EINVAL`, spikes §2); SLIM gated by a launch probe (`EINVAL` → plain RECURSIVE). Error callback collects (path, errno), returns SKIP; `EACCES` in user-owned tree → `u+w` on parent, one retry. After return: `fstatat` the entry; freed bytes credited only if gone, else outcome `partial` with errors. Cancel = `removefile_cancel` only at app quit (committed items otherwise drain; leftovers swept next launch). Never `ALLOW_LONG_PATHS`.
- [ ] **Trash:** `TrustedRoot` open + identity check on the fd, then immediately `FileManager.trashItem(at:resultingItemURL:)` on the original URL (keeps Finder Put Back, spikes §4; never trash from staging). Accepted window: URL re-resolution between check and call (threat model). No Trash → `.noTrash`, never delete instead. `evict` (`evictUbiquitousItem`), `simctl` (`xcrun simctl delete unavailable`, 60 s), Empty Trash = journal remove of `~/.Trash` children with `uchg` cleared on user-owned files.
- [ ] **cancelClean:** stops further detaching; already-committed items drain. Stream: `.item` per processed item → `.freed` as deletions finish → exactly one `.finished(report)` (with `cancelled`) after detach stops **and** the drain completes; then the stream finishes. Window close = `cancelClean`; the engine keeps draining with no subscriber.
- [ ] **Undo** (`dataDirectory/storage-undo.json`): record per entry the actual Trash parent from `trashItem`'s `resultingItemURL` (home `~/.Trash` or a volume's `.Trashes/<uid>`) plus that parent's (dev, ino); at undo open `TrustedRoot(recorded trash parent)`, verify its identity, then verify the item's recorded identity at the Trash source (`fstatat`) — mismatch → reported, nothing moved; recreate missing destination parents fd-relatively (`mkdirat` + `openat(O_NOFOLLOW|O_DIRECTORY)`); `renameatx_np(RENAME_EXCL|RENAME_NOFOLLOW_ANY)`, `EEXIST` → retry `name (restored)`, `name (restored 2)`…; event `.restored(itemID, finalPath)`; prune when gone or > 7 d.
- [ ] **InUseChecker:** `proc_listpids` + per pid cwd, `proc_pidpath`, vnode fds (spikes §5); match = equal or prefix + "/"; `EPERM` pids counted as unknown holders (advisory).
- Tests (real temp dirs, injected `permittedRoot`, `dataDirectories`):
  - `StagingTests`: identity mismatch (dir replaced after scan) → rolled back, original intact — bug: deleting a different file. Crash after pending rename (simulate: stop after step 2) → sweep restores to original — bug: user data lost in pending. Rollback collision (original name re-created) → left in pending, reported, never deleted. Staging on other volume (fake dev) → `.stagingOtherVolume`, item intact. Sweep deletes `commit/` only.
  - `DenylistTests`: protected descendant absent from the tree (target `Caches/dev.telltale-dev` whose child is the injected data dir, tree lacking it) → `.denied(.protected)` — bug: trusting scan data. File directly inside `Keychains` → `.denied(.protected)` (inside). `~/Library` and a parent of it → `.anchor`. Case/NFD variant spelling of a protected dir (APFS case-insensitive temp) → refused. Chain unestablishable (EACCES ancestor) → `.unverifiable`.
  - `CleanerTests`: keep-parent with a child created after scan → handled from live listing, parent kept, outcome counts right — bug: removing parent / missing children. Mid-path symlink outside root → refused. Remove mode outside `~` refused. `EACCES` subtree → chmod retry. Partial delete failure (immutable file inside committed tree) → not credited as freed, outcome partial. Cancel before first item → zero detached, `.finished(cancelled)`; cancel between items → detached ones drain and are freed, rest untouched; stream emits exactly one `.finished` — bug: hang or lost committed items. Vanished before detach: remove = success 0 B; trash = 0 B noted. Fake no-Trash → `.noTrash`, file present. `uchg` in fake Trash removed. Freed = Σ of fully removed items only.
  - `UndoTests`: restore; collision → `name (restored)`; missing parent recreated; substituted Trash entry (different inode same name) → refused, reported; symlinked destination parent → refused, nothing written through link; non-home Trash parent (temp dir standing in for `.Trashes/<uid>`) → restored.
  - `InUseTests`: open `/a/b/c` marks `/a/b`, not `/a/bc`.
  - Break-check: remove the identity check once → mismatch test red, revert.
- Gate: `scripts/ci.sh StagingTests DenylistTests CleanerTests UndoTests InUseTests`.

### W2d — UIKit

Prefix `feat(uikit):`. Files `Treemap/{TTSpaceMap,SpaceMapHitTest}.swift`, `Treemap/TreemapLayout.swift`, `Components/{TTTable,TTToast,TTTableCheckbox}.swift`, `Gallery/**` (new items).

- [ ] **First commit:** capture current `TreemapLayout.squarify` output for 200 seeded inputs into `Tests/MonitorUIKitTests/TreemapBaseline.swift` (generated Swift literals; no Package change).
- [ ] `TreemapLayout.squarify(presorted:)` skipping the sort (`TreemapLayout.swift:41`); incremental row min/max → O(1) per growth step (today `worstRatio` rescans the row, `:47-77`). Old entry point kept for `TTTreemap` (`TTTreemap.swift:12-13`).
- [ ] `TTSpaceMap` (spec §4.7): one `Canvas` (precedent `TTChartCanvas`, `TTAreaChart.swift:115`), cached rects, `onContinuousHover`, hover overlay reading only a `hoveredID` binding, one tooltip, cached hatch, no drill animation, `.accessibilityChildren`.
- [ ] `TTTable`: optional `hover: Binding<Row.ID?>`; row `==` (`TTTable.swift:309`) includes `isHovered` (today per-row `@State hovering`, `:306`, `:347`). `TTTableCheckbox` (DESIGN §2.29 style), Space toggles.
- [ ] `TTToast`: keep `lifetime` (4 s; used at `PopoverRoot.swift:41`, `ThermalsPage.swift:869`, `W5aPageSupport.swift:443`) unchanged; add `static let undoLifetime = .seconds(10)` and `static func lifetime(hasUndo:)`. New init with `actions: [TTToast.Action]` (`show`, `emptyTrash`, `undo`); order text · Show · Empty Trash · Undo; Show only when skips > 0, Empty Trash only when trashed > 0, Undo only for trash undo; `init(_:undo:)` source-compatible. Activating Show pins the toast until its sheet closes; any other action dismisses it.
- [ ] Gallery items `space-map`, `space-map-restricted`, `table-checkbox`, `toast-actions` → `ComponentSnapshotTests.ids` (`ComponentSnapshotTests.swift:11-14`).
- Confirm dialog: no change — `TTConfirmDialog` wraps multi-line text (`TTConfirmDialog.swift:52-56`).
- Tests:
  - `TreemapLayoutTests`: presorted path vs `TreemapBaseline` (±1e-9) — bug: refactor changes layouts.
  - `SpaceMapHitTestTests`: shared edges, "smaller" tile, gutter → expected id/nil — bug: wrong tile hovered/drilled.
  - Hover-redraw claim: no body-evaluation hook exists in TTTable → **no test** (design note only); advisory perf instead.
  - snapshots of new gallery items after visual check; perf advisory: 10k-child cutoff + capped layout < 2 ms.
- Gate: `scripts/ci.sh TreemapLayoutTests SpaceMapHitTestTests TTTableTests ComponentSnapshotTests`.

### W3a — StorageModel (MonitorLive)

Prefix `feat(storage-model):`. Files `Sources/MonitorLive/Storage/{StorageModel,ScanProgressState,SpaceMapState,CleanupState,HoverState}.swift`.

- [ ] `@MainActor @Observable StorageModel(actions:)`; sub-objects per spec §3.3. Phases `.idle(summary)`, `.loadingCache`, `.scanning(previous:)`, `.ready`, `.failed`. Holds `tree` + `overlay`; `SpaceMapState` keyed by `(tree.version, overlay.version)`.
- [ ] Cleanup: checked `Set<Int32>` (default `.safe && !runningApp && !ignored && mode != .none`); selection totals via `ReclaimAccumulator` (insert/remove per toggle); "≈" when provenance ≠ `.exact`; lines cached per (category, sort, expansion, showIgnored, versions). `Show ignored` toggle filters `ignored`.
- [ ] Clean events: `.item` → `overlay.remove(removedNodes)` / `shrink` for keep-parent partial; remove only committed items/children from lists; `.restored` → `overlay.restore`. Owns clean/undo tasks + latest `UndoRecord`.
- [ ] Lifetimes: page switch → nothing cancelled; `windowDidClose()` → `cancelScan`, `cancelClean`, `release`, drop tree/overlay/cleanup, keep summary; `pageDidAppear()` → `loadCached`.
- [ ] `classifyOptions` set by the page from SettingsStore (Live can't import Screens; `Sources/MonitorScreens/Shell/SettingsStore.swift`).
- Tests `StorageModelTests` (mock streams):
  - toggle / detach / undo keep totals equal to a fresh `ReclaimAccumulator` — bug: drift or double subtract.
  - keep-parent partial outcome: parent stays, size shrinks by `detachedBytes`, not removed — bug: UI drops data still on disk.
  - rescan keeps previous tree until `.finished`; `.failed` keeps previous — bug: blank map.
  - window close: scan + clean cancelled, tree nil, summary kept; page switch: scan continues.
  - observation isolation: progress tick doesn't fire `SpaceMapState`/`CleanupState` observers (pattern `Tests/MonitorLiveTests/LiveModelTests.swift:8-18`) — bug: page re-renders at 10 Hz.
- Gate: `scripts/ci.sh StorageModelTests`.

### W3b — engine, runtime composition, StorageActionsLive, app wiring

Prefix `feat(storage-runtime):`.

- [ ] `MonitorDiskTools/Engine/StorageEngine.swift`: serial utility queue for classify/resolve/private sizes/Spotlight/installed apps; pipeline scan → classify → `.classified` → `platform.appPaths` resolve → private sizes → `.classified(final)` → cache save (success only). Generation counter bumped by `release()` and each new scan; results from older generations are dropped. `release()` drops tree, overlay, installed set, Spotlight map. After clean/undo: `saveOverlay`; write `dataDirectory/storage-summary.json` (home root only: reclaimable + provenance, trash bytes, scan date). Launch: `Staging.sweep`, `UndoStore.prune`, SLIM/RESOLVE probes.
- [ ] `MonitorRuntime/StoragePipeline.swift`; `TelltaleRuntime` (`TelltaleRuntime.swift:34-76`) exposes `storage`, `storageActions`; `make(…, storagePlatform:)` (default `.none`); mock → `MockPipeline.storageActions` (W3c; signature agreed in progress files day 1).
- [ ] `MonitorScreens/Shell/StorageActionsLive.swift` (next to `ProcessActionsLive.swift`): reveal (`activateFileViewerSelecting`), FDA pane URL, `ignore`/`unignore` → SettingsStore; `platform()` → `runningApplications`, `urlsForApplications(withBundleIdentifier:)`, `willUnmountNotification` stream.
- [ ] `SettingsStore` keys `storage.ignoredPaths`, `storage.largeThreshold`, `storage.oldThreshold` (style `SettingsStore.swift:19-20`).
- [ ] `ShellContext` (`ShellEnvironment.swift:10-44`) gains `storage`, `storageActions` with defaults so `ScreenCatalog.context` (`ScreenCatalog.swift:60-67`) compiles unchanged; inject in modifier (`:84-95`); `@Entry storageActions = .noop` in `EnvironmentValues+Telltale.swift:7-13`.
- [ ] App: `AppEnvironment.swift:49` (`TelltaleRuntime.make`), `:70` (`ShellContext`); `DashboardWindowController` close → `storage.windowDidClose()`.
- Tests:
  - `StorageRuntimeTests` (temp home, permitted root = temp): fixture cache dir `Library/Caches/com.example.storage-fixture` (id matches no exclusion) appears as a selectable User Caches item **before** cleaning (assert first) → clean → gone, freed > 0, overlay + summary written; cancelled scan writes no cache — bug: wiring drops events / caches partial results / fixture silently excluded.
  - delayed completion after close: classify stub completes after `release()` → no `.classified` delivered, no state retained — bug: late results resurrect released tree.
  - `ShellStorageTests`: `ignore` persists in `InMemoryDefaults`, next reclassify marks it ignored; `unignore` clears.
- Gate: `scripts/ci.sh StorageRuntimeTests ShellStorageTests RuntimeTests`.

### W3c — mocks

Prefix `feat(storage-mocks):`.

- [ ] `MockStorageState` (`empty`, `scanning`, `map`, `cleanup`, `noFDA`): deterministic tree via `StorageTreeBuilder` (~2k nodes), `CleanupSet` over all 5 categories incl. running-app, in-use, ignored, estimate-provenance items; `MockDataProvider.referenceDate` (`MockDataProvider.swift:48`).
- [ ] `MockDataProvider.storageActions(log:)` next to `processActions(log:)` (`:231`): canned streams, no disk; `ActionLog.Kind` (`ActionLog.swift:8`) += `scan, clean, cancelClean, undo, emptyTrash, trash, ignore, unignore, revealInFinder`.
- [ ] `MockPipeline.storageActions` for `--mock`.
- Tests `StorageMockTests`: `clean(ids)` logs exactly those ids, emits one `.item` per id then one `.finished` — bug: confirm-flow tests pass vacuously.
- Gate: `scripts/ci.sh StorageMockTests`.

### W4a — page shell, Space Map, states

Prefix `feat(storage-ui):`.

- [ ] `StoragePage` per DESIGN §3.17: header trailing via `pageHeaderTrailing` (`PageHeader.swift:44`, precedent `ProcessesPage.swift:71`); FDA banner; stat strip (`ShellFormat.freeSpace` `ShellFormat.swift:11`; Purgeable drops at 1100, `ShellStyle.swift:45`); `TTSegmented` (`TTSegmented.swift:7`); Cleanup disabled outside `~`.
- [ ] `SpaceMapView`: breadcrumb, `TTSpaceMap` + children table (Items column drops at 1100), shared `HoverState`, smaller-items via `cutoff`, restricted hatch, overlay-aware sizes; menu Reveal · Move to Trash… (disabled with `policy().denyReason` tooltip; enabled → confirm → `clean([item with .trash])`) · Ignore; keyboard.
- [ ] `StorageStates` (spec §4.5; `TTEmptyState.swift:7`).
- Gate: `scripts/ci.sh --no-tests`; `scripts/render.sh storage calm`.

### W4b — Cleanup mode + clean flow

- [ ] `CleanupView`: category card + item table (`sortsRows: false`; precedent `TTTableStyle.processes`, `TTTable.swift:402`), checkbox, tier / In use badges, owner `TTAppTile` (`AppIconCache` `TTAppTile.swift:86`, as-is), group rows, Large & Old threshold `TTSegmented`, `Show ignored` + Unignore, sticky footer `Selected [≈]X · N items` + `Clean…`.
- [ ] `CleanConfirm` (spec §7.1): `checkInUse` → untick + notice → `await confirm?.confirm(…)` (`ConfirmDialogHost.swift:49`) with lines delete permanently / move to Trash / remove downloads + in-use list capped at 5 + "+N more" → `clean` → footer `Cleaning 12/37…` + Cancel (`cancelClean`) / `Freeing…`. In-use prewarm when Cleanup opens (~19 ms, spikes §5).
- [ ] `CleanToast` (DESIGN §3.12 rules): `Freed X · Moved Y to Trash` + Show / Empty Trash / Undo. Empty Trash from the toast goes through confirm too.
- Tests `StorageCleanupTests` (`MockDataProvider.storageActions(log:)` + `ActionLog`): cancelled confirm → nothing logged; confirmed → logged ids == checked minus newly in-use — bug: delete without confirm / delete in-use. Toast Empty Trash without confirm → nothing logged. Message builder: 7 in-use → 5 + "+2 more"; trashed bytes never in "Freed".
- Gate: `scripts/ci.sh StorageCleanupTests`.

### W4c — sidebar, popover, catalog

- [ ] `Sidebar.value` (`Sidebar.swift:52`) takes `StorageSummary?` (home root): `{n} GB reclaimable` (with `≈` rule) after a scan, else free space (current `.disk` branch `:69-73`).
- [ ] "Free up space…" per DESIGN §3.1 → `appCommands.openDashboard(.storage)` (`AppCommands.swift:5`); row model `PopoverModel.swift:82-89`.
- [ ] `ScreenCatalog`: `dashboard(_:scenario:)` (`ScreenCatalog.swift:76`) gains size + storage state; entries listed in §4 W4-final.
- Tests: sidebar reclaimable vs no-scan free space (`ShellCompositionTests`); link opens `.storage` (`PopoverTests`) — bugs: stale sidebar value, link opens Disk.
- Goldens: re-record only those that change among `popover-calm`, `popover-collecting`, `popover-deviceUnknown`, `popover-paused`, `popover-sensorsUnavailable`, `popover-alert-thermalFair`, `popover-flyout-calm`, `popover-footer-overlay-on`, `flyout-*`; list them in the progress file.
- Gate: `scripts/ci.sh ShellCompositionTests PopoverTests FlyoutTests`.

### W4-final (W4a owner)

- [ ] ScreenCatalog ids (exact): `storage` (auto from `DashboardPage.allCases`, default state = empty), `storage-1100`, `storage-scanning`, `storage-scanning-1100`, `storage-map`, `storage-map-1100`, `storage-cleanup`, `storage-cleanup-1100`, `storage-nofda`, `storage-nofda-1100`. Sizes 1280×860 / 1100×720.
- [ ] `StorageSnapshotTests`: `assertScreen` (`Tests/MonitorScreensTests/Support/ScreenTestSupport.swift:62`) for all 10 ids on `.calm` → goldens `storage-calm`, `storage-1100-calm`, `storage-scanning-calm`, `storage-scanning-1100-calm`, `storage-map-calm`, `storage-map-1100-calm`, `storage-cleanup-calm`, `storage-cleanup-1100-calm`, `storage-nofda-calm`, `storage-nofda-1100-calm`.
- [ ] Render each (`scripts/render.sh <id> calm`), Read PNGs, compare with DESIGN §3.17 (no artboards — user decision); fix, re-render.
- [ ] Real app: `scripts/install.sh` → `/Applications/Warden.app` (user granted FDA there); scan `~`; screenshot Space Map, Cleanup, confirm, toast. Dev build (`scripts/run.sh --open-dashboard storage`, no FDA) → banner state. Clean a throwaway `~/Library/Caches/com.example.storage-fixture` via the UI (assert listed first); Undo a trashed throwaway file; check Finder Put Back on another trashed throwaway (spikes §4 user check) and record result in DESIGN/RULINGS.
- Gate: `scripts/ci.sh StorageSnapshotTests StorageCleanupTests ShellCompositionTests PopoverTests ComponentSnapshotTests`.

---

## 5. Merge order

1. W1 → review → P1 fixes. 2. W2a–d as green → review (W2c `xhigh`). 3. W3a, W3c, then W3b → review (`xhigh`). 4. W4a–c, W4-final → review; screenshots in progress file. 5. Ask user: merge `feat/storage` → `dev`.

---

## 6. Spike-confirmed choices (`docs/findings/storage-spikes.md`)

| # | Choice | Probe / fail-closed behavior | Owner |
|---|---|---|---|
| S1 (§1) | `openat` with `O_RESOLVE_BENEATH | O_NOFOLLOW_ANY` under a trusted root fd | launch probe (`..` must fail `ENOTCAPABLE`; mid-path symlink must fail `ELOOP`); any probe failure → per-component walk `O_NOFOLLOW|O_DIRECTORY` + `fstat` identities (never "unchecked open") | W1 `SafePath`, W2c |
| S2 (§2) | `removefileat(… RECURSIVE | RECURSIVE_SLIM)` + **error callback only**; cancel via `removefile_cancel`; errno read from state, not return | SLIM probe at launch (`EINVAL` → plain RECURSIVE). Never confirm/status callbacks (SLIM + them → `EINVAL`, nothing removed) | W2c |
| S3 (§3) | `ATTR_CMNEXT_PRIVATESIZE` in the same `getattrlistbulk` call (`forkattr` + `FSOPT_ATTR_CMN_EXTENDED`) | read only if the returned bit is set, else provenance `.estimate`; clone sets → private is a lower bound (UI "≈"/tooltip) | W2a |
| S4 (§4) | `FileManager.trashItem` on the original URL (system writes Put Back info); undo via own record | no Put Back claim in UI until W4-final Finder check | W2c, W1 docs |
| S5 (§5) | in-use pass inline (median 19 ms, advisory); prewarm on Cleanup open + recheck at Clean; `EPERM` pids = unknown holders | handle `EBUSY`/`EPERM` at delete time regardless | W2c, W4b |
| S6 (§7) | `renameatx_np(RENAME_EXCL | RENAME_NOFOLLOW_ANY)` with (dir fd, leaf name) | unknown flag → `EINVAL` → fail closed: skip item (`failed`); leaf-name renames can't traverse symlinks anyway | W2c |
| S7 (§8) | `setiopolicy_np(MATERIALIZE_DATALESS_FILES_OFF)` per scanner thread | rc ≠ 0 → don't enter dataless dirs (already the rule) | W2a |
| — | cold scan, 14.x behavior, dataless no-materialize with a real placeholder | not verified (user action); advisory | — |

---

## 7. Spec drift (verified at `a9b430c`)

| Spec says | Actual / correction |
|---|---|
| macOS 14 spikes/baseline | target is macOS 15 (`Package.swift:19`, `project.yml:5`); `Mutex` allowed |
| ICR `016` | ICR-16 = Overlay (`docs/ARCHITECTURE.md:1442`); 017 claimed by network spec (`…network-monitor-design.md:402`) → **018** |
| DESIGN "new §3.16" | §3.16 = Overlay (`DESIGN.md:1152`) → **§3.17** |
| `ARCH:157` | `docs/ARCHITECTURE.md:159`; doc-only → W1 adds ci grep |
| `project.yml:35-36` | products `project.yml:41`; app is **Warden** (`:1`, `:23`) |
| `ci.sh:40` | `scripts/ci.sh:50-56`; currently red on Mixer `TapVolumeController.swift:6` |
| `install.sh:40` ad-hoc every install | `scripts/install.sh:42-45` already signs with env/keychain Apple Development, else ad-hoc |
| `PageHeader.swift:142` | switch `:114`, nil branch `:144` |
| `TTIcon.swift:35,105` | enum `:7-9`, svg switch `:13`, `page()` `:99` |
| switch list incl. LaunchOptions, probe Options, ShellSnapshotTests | no edit (`LaunchOptions.swift:65`, `Options.swift:98`, `ShellSnapshotTests.swift:23`); real work = 3 goldens + `GalleryPopover.swift:45-55` |
| `TTAreaChart.swift:78` | `TTChartCanvas` at `TTAreaChart.swift:115` |
| `TTTable` `:282-286`, `:350` | `==` `:309`, per-row `@State` hover `:306/:347`, `.processes` `:402` |
| confirm multi-line (`ConfirmDialogHost.swift:7-13`) | already supported (`TTConfirmDialog.swift:52-56`) |
| `@Entry storageActions` location | `Sources/MonitorUIKit/Environment/EnvironmentValues+Telltale.swift:7-13`; `ShellContext` in `Shell/ShellEnvironment.swift:10` |
| SettingsStore-backed thresholds for DiskTools | `SettingsStore` is in MonitorScreens (`SettingsStore.swift:19-20`) → `ClassifyOptions` |
| exclude `dev.telltale*` | + `dev.warden` (`AppEnvironment.swift:76`), legacy `:81`, dev data `~/Library/Caches/dev.telltale-dev/<wt>` (`scripts/run.sh:16`) |
| `storage-scan.bin` | per root `storage-scan-<hash>.bin` + `.overlay.json` |
| §5.8 relative time | no rule at `DESIGN.md:1333-1342` → W1 adds |
| arena (§5.3) | + `fileID`, `linkGroups`; sorted via `childOrder` (stable IDs) |
| hard links (§5.5) "count only if all links inside" | counted over the selection union (`ReclaimAccumulator`) |
| denylist "contains from scan data" (§7.4) | live identity chains; anchors vs protected subtrees |
| staging single dir + direct `removefile` fallback (§7.2) | pending/commit journal; no cross-volume fallback |
| `CleanEvent.detached` | `.item(CleanItemOutcome)`, `.restored`; + `cancelClean`, `release`, `policy`, `unignore` |
| perf "1M entries ≤ 5 s warm" | measured ~125k entries/s → ≈ 8 s/1M; advisory |
| icons warmed off-main | `AppIconCache` internal `@MainActor` (`TTAppTile.swift:86`); reused as-is |
| ARCH §2 ProcessActionsLive in App (`:74`) | `Sources/MonitorScreens/Shell/ProcessActionsLive.swift` (ARCH stale) |
| Verified OK | `Sidebar.swift:52`, `TreemapLayout.swift:41`, `TTToast.swift:10-23`, `project.yml:11-12`, `ShellStyle.swift:45`, `VolumeSensor.swift:14`, `TTTreemap.swift:12-13`, `PopoverRoot.swift:37,41` |

Rejected/adjusted from review r1: item 17 — cache not rewritten after clean; overlay persisted as a sidecar (`saveOverlay`) instead: same result on reload, no 13 MB re-serialization per clean. Item 27 — redraw test dropped (no body-evaluation hook; adding one = test-only prod code).

---

## 8. Unresolved questions

None. Resolved 2026-10-04: ICR 018; `@unchecked` gate fixed in MixerCore (f08eb24); perf target stays advisory, report measured entries/s.
