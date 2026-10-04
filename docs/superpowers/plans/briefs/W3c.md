# W3c brief — storage mocks

Self-contained. Source of truth order: **W1 code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §3, §4 W3c). W1 type differs from this brief → code wins; record it in your progress file. Read `docs/superpowers/plans/progress/W1.md` "Interface deltas" first.

Paths are under `MonitorCore/` unless they start with `docs/`, `scripts/`, `App/`.

## Goal

Deterministic storage fixture data and canned `StorageActions` that never touch disk: `MockStorageState` (5 states for W4 renders/goldens), `MockDataProvider.storageActions(log:state:)` logging every call into `ActionLog`, and `MockPipeline.storageActions` for `--mock` runs. W4b's confirm-flow tests and W4-final goldens depend on this. Depends on W1 only.

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w3c`, branch `ws/storage-w3c` (orchestrator creates it from `feat/storage`). Work, test, commit only there; rebase on `feat/storage` before handing back. **Do not merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (add `.codegraph/` to `$(git rev-parse --git-common-dir)/info/exclude` if it shows up); else `codegraph sync -q`. `codegraph explore "<symbols>"` before grep.

## Ownership

Own: `Sources/MonitorMocks/{MockStorageState,MockDataProvider,ActionLog}.swift`, `Sources/MonitorRuntime/MockPipeline.swift`, `Tests/MonitorMocksTests/Storage*`, `docs/superpowers/plans/progress/W3c.md`.

Must not touch: `Sources/MonitorModel/**` (W1, frozen), `Package.swift`, `Sources/MonitorRuntime/{TelltaleRuntime,LivePipeline,StoragePipeline}.swift` (W3b), `Sources/MonitorLive/**` (W3a), `MonitorScreens`, `App/`. Need a change there → "Requests" in progress file.

## APIs consumed (W1, verified at `64c8bf1`)

- `StorageActions` `Sources/MonitorModel/Storage/StorageServices.swift:28` (fields `:29-52`, init with defaults `:54`). Shape precedent: `MockDataProvider.processActions(log:)` `Sources/MonitorMocks/MockDataProvider.swift:231`.
- `StorageTreeBuilder` `StorageTreeBuilder.swift:32` (`init(root:dev:volumeUUID:rootFileID:rootMtime:)`), `appendChildren` `:46`, `setDirFacts` `:60`, `setRestricted` `:65`, `addSmall` `:70`, `addLink` `:81`, `snapshot()` `:101` (partial tree), `finalize(scanDate:lastEventId:)` `:106`. `NodeRecord(name: String, …)` `StorageBasics.swift:88`, `StorageNodeFlags` `:6` (`.restricted`, `.package`, `.hidden`, `.buildDir`). Fixture precedent: `Tests/MonitorModelTests/StorageTreeTests.swift:6-20`.
- `StorageTree.path(_:)` `StorageTree.swift:101`, `lookup(path:)` `:151`, `identity(_:)` `:118`; `StorageTreeOverlay(tree:)` `StorageTreeOverlay.swift:91`.
- `CleanupItem` init `Cleanup.swift:81`, `CleanupSet` init `:132`, `OwnerApp` `:42`, `LinkGroupSize` `:111`; `ScanEvent` `StorageScan.swift:41`, `ScanProgress` `:22`; `CleanEvent` `Clean.swift:55`, `CleanItemOutcome` `:41`, `CleanReport` `:74`, `UndoRecord` `:92`, `UndoEntry` `:109`, `StorageSummary` `:129`; `StoragePolicy` `StoragePolicy.swift:14` (`.none` `:21`).
- `ActionLog` `Sources/MonitorMocks/ActionLog.swift:7` (`Kind` `:8` — `revealInFinder` already exists, reuse it), `record(_:target:result:)` `:34`; `ActionResult` `Sources/MonitorModel/Services/ProcessActions.swift:35`.
- `MockDataProvider.referenceDate` `MockDataProvider.swift:48`; seeded hashing `Sources/MonitorMocks/Support/SplitMix64.swift:8` (`hash(seed,index)`), `:17` (`unit`).
- `MockPipeline` `Sources/MonitorRuntime/MockPipeline.swift:12` (init `:20`, provider built at `:21`).

## API to implement (record final signatures with file:line — W3b, W4 code against them)

```swift
public struct MockStorageState: Sendable {
  public enum Kind: String, CaseIterable, Sendable { case empty, scanning, map, cleanup, noFDA }
  public static let home = "/Users/demo"
  public static func make(_ kind: Kind, referenceDate: Date = MockDataProvider.referenceDate) -> MockStorageState
  public var kind: Kind
  public var tree: StorageTree?            // nil for .empty; partial snapshot for .scanning
  public var overlay: StorageTreeOverlay?
  public var cleanup: CleanupSet?          // nil for .empty/.scanning
  public var progress: ScanProgress?       // .scanning only
  public var hasFullDiskAccess: Bool       // false for .noFDA
  public var summary: StorageSummary?
  public var inUseIDs: Set<Int32>          // returned by checkInUse
  public var policy: StoragePolicy
}
extension MockDataProvider {
  public func storageActions(log: ActionLog, state: MockStorageState = .make(.map)) -> StorageActions
}
ActionLog.Kind += scan, clean, cancelClean, undo, emptyTrash, trash, ignore, unignore   // revealInFinder exists
ActionLog.storageItemIDs: [Int32]          // ids from .clean/.trash entries, in call order
MockPipeline.storageActions: StorageActions // agreed with W3b: W3b adds `var storageActions: StorageActions { get }` to RuntimePipeline
```

## Data rules

- Deterministic: no `Date()`, no `UUID()` (use fixed UUIDs), no `random`; seeded `SplitMix64` only. Two `make(k)` calls → equal `CleanupSet`s and equal tree arrays (versions differ: `StorageTree.nextVersion()` is a process counter — never compare versions).
- Tree (~2k nodes) under `.home(MockStorageState.home)`: `Library/{Caches,Application Support,Containers,Developer/Xcode/DerivedData,Logs}`, `Documents`, `Downloads`, `Movies`, `Projects/<p>/node_modules`, `.Trash`; ≥ 1 `.restricted` dir (in every state; `.noFDA` has several); ≥ 1 `.package` (`.app`/`.photoslibrary`); one hard-link group across two cleanup items; folded small files via `addSmall`. Sizes plausible for a 1 TB disk (tens of GB), sized for readable Space Map tiles.
- `CleanupSet` (`treeVersion == tree.version`, `ownershipResolved = true`, `privateSizesFinal = true` except estimate items) covering all 5 categories; each item's `path == tree.path(nodeID)`, no item inside another; includes: ≥ 2 items with the same `owner.bundleID` in one category (W3a grouping), a `runningApp` item, an item listed in `inUseIDs`, an `ignored` item, `.estimate` and `.exact` provenance, a `mode: .none` item (Docker note), a `.evict` item, a keep-parent cache dir. `trashBytes` = `.Trash` size. Owners from familiar apps (reuse names/bundle ids from `Support/DemoApps.swift:36` where they fit).
- `.scanning`: `tree = builder.snapshot()` of a partly built tree, `progress = ScanProgress(files: 182_340, bytes: …, currentPath: "/Users/demo/Library/Caches/…")`.
- Actions (all `@MainActor`, no disk, no sleeps; streams yield everything, then finish):
  - `scan` → logs `.scan` (target = root path); yields 3 `.progress`, 1 `.partial`, `.finished(tree)`, `.classified(set)` from `make(.map)`.
  - `clean(items)` → per item logs `.trash` if `mode == .trash` else `.clean` (target `"\(id)"`); yields one `.item` per item in input order (non-keep-parent: `removedNodes = [nodeID]`, `detachedBytes = privateBytesExcludingLinks ?? allocBytes`; keep-parent: its node-children ids, `committedChildren = count`; items in `inUseIDs` → `skip: .inUse`), one `.freed(Σ removed)`, one `.finished(report)` (`undo` with an entry per trashed item, fixed UUID, `date = referenceDate`).
  - `undo(record)` → logs `.undo`; `.restored(itemID, originalPath)` per entry, then `.finished`. `emptyTrash` → logs `.emptyTrash`; `.finished` with `freedBytes = trashBytes`. `cancelClean` → logs `.cancelClean`.
  - `loadCached` → `(tree, overlay, cleanup)` for map/cleanup/noFDA, nil for empty/scanning. `loadSummary` → `summary`. `reclassify` → `cleanup`. `checkInUse(items)` → `inUseIDs ∩ ids`. `policy` → `state.policy` (anchors: root, `Library`; protected: `Library/Mail` if present). `availableRoots` → `[.home(home), .volume(path: "/Volumes/Backup", name: "Backup")]`. `hasFullDiskAccess` → state. `ignore`/`unignore`/`revealInFinder` → log with the path. `openFDASettings`, `release` → no log (no kind in plan).
- `MockPipeline`: `let storageActions: StorageActions` = `provider.storageActions(log: ActionLog())` (state `.map`) built in `init` (`:20-25`). Do not touch `TelltaleRuntime` — W3b adds the protocol requirement and creates the `StorageModel`.
- `ActionLog` is already `@unchecked Sendable` (`ActionLog.swift:7`; allowed only in MonitorMocks, `scripts/ci.sh:63-69`). Add **no new** `@unchecked`; `MockStorageState` is plain `Sendable` (`StorageTree` is a `Sendable` final class).

## Tasks (commit per task, prefix `feat(storage-mocks):`)

- [ ] **T1 `MockStorageState`** builder + 5 kinds. Accept: `StorageMockTests` invariants test green.
- [ ] **T2 `ActionLog.Kind` cases + `storageItemIDs`; `MockDataProvider.storageActions(log:state:)`.** Accept: clean-log test green.
- [ ] **T3 `MockPipeline.storageActions`.** Accept: `scripts/ci.sh --no-tests` builds; record the property signature in the progress file for W3b.

## Tests (`Tests/MonitorMocksTests/StorageMockTests.swift`; each names its bug)

- `clean(ids)` for 4 items (mixed `.trash`/`.remove`, one in `inUseIDs`) → `log.storageItemIDs` == exactly those ids in order, each once; stream = 4 `.item` in input order, ≤ 1 `.freed`, exactly one `.finished`, last; in-use item's outcome `skip == .inUse` — bug: W4b confirm-flow tests pass vacuously (logs missing/extra ids) or hang waiting for `.finished`.
- Fixture invariants, parametrized over `Kind.allCases`: same kind twice → equal `CleanupSet` and equal tree `allocBytes`/`names`; for states with a set: every item's `tree.path(nodeID) == path`, no item path inside another item's, all 5 categories present, at least one each of runningApp / inUse / ignored / `.estimate` / `mode .none` / same-owner pair — bug: flaky goldens, or a W4 state never exercising a badge.
- No test for canned returns of `loadSummary`/`policy` etc. (mock returns X → assert X).
- Break-check: drop the last item in `clean` → first test red; revert. Quote both runs.

## Gates

- Iterate: `scripts/test.sh StorageMockTests`.
- Merge gate: `scripts/ci.sh StorageMockTests MockPipelineTests ActionLogTests` → `ci.sh: OK`; quote it.

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No new `@unchecked`, no `as any`/lint disables, no swallowed errors.
- Comments explain why. No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines: pipe through `tail`/`grep`.
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefix `feat(storage-mocks):`; message ends with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W3c.md`: Plan / Done (hashes) / Next / Interface deltas (final signatures with file:line) / Requests / Not verified / Blockers.
- Don't merge; don't run Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, interface deltas, not verified.
