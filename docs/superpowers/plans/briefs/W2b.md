# W2b brief — classifier, installed apps, Spotlight last-used

Self-contained. Source of truth order: **W1 code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §4 W2b; spec `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` §6). If a W1 type differs from this brief, the code wins; record the mismatch in your progress file. A Codex review of W1 may land small contract fixes before you start — re-read the cited files.

Paths below are under `MonitorCore/` unless they start with `docs/`, `scripts/`, `App/`.

## Goal

Pure, fast classification of a finished `StorageTree` into a `CleanupSet` (User Caches, Leftovers, Large & Old, Developer, Trash), with two-stage app ownership, plus the installed-app set and the Spotlight last-used query. No filesystem writes. W3b composes it in `Engine/StorageEngine.swift` (not yours).

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w2b`, branch `ws/storage-w2b` (created from `feat/storage` by the orchestrator after W1 merged). Work, test, commit only there. Rebase on `feat/storage` before handing back. **Do not merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (if `git status` then lists `.codegraph/`, add it to `$(git rev-parse --git-common-dir)/info/exclude`); else `codegraph sync -q`. Use `codegraph explore "<symbols>"` before grep.

## Ownership

Own: `Sources/MonitorDiskTools/Classify/**` (`BundleID, InstalledAppSet, SpotlightLastUsed, Classifier, CategoryRules, BuildDirRules, DevToolProbe, GitTracking`.swift), `Tests/MonitorDiskToolsTests/{Classifier,BundleID,InstalledApps,BuildDir}*`, `docs/superpowers/plans/progress/W2b.md`.

Must not touch: everything else — `Sources/MonitorModel/**`, `Sources/MonitorDiskTools/{DiskTools.swift,Support/**,Scan/**,Cache/**,Clean/**,Engine/**}`, `Tests/MonitorDiskToolsTests/Support/**` (incl. `TreeFixture.swift`, W1), `Package.swift`, `scripts/**`, other docs.
Escalation: a needed change in a file you don't own → local extension in your own files (e.g. test helpers in `ClassifierTestSupport.swift` matching your owned glob `Classifier*`), record it under "Requests" in your progress file.

## W1 APIs you consume (verify; code wins)

- `StorageTree` `Sources/MonitorModel/Storage/StorageTree.swift:9`: arrays `flags`, `markerMask`, `mtime`, `subtreeMaxMtime`, `addedTime`, `allocBytes`, `linkGroups`; `name(_:)` `:96`, `path(_:)` `:101`, `size(_:)` `:114` (nil = restricted), `identity(_:)` `:118`, `sortedChildren(_:)` `:123`, `isAncestor(_:of:)` `:129` (proper ancestor only), `depth(_:)` `:139`, `lookup(path:)` `:151` (exact bytes; trailing slash → nil).
- `StorageNodeFlags` `StorageBasics.swift:6-25` (`package`, `restricted`, `hidden`, `dataless`, `buildDir` `:25`); `StorageMarker` `:30-47`; `FileIdentity` `:51`; `HardLinkGroup` `:96` (`occurrences` = file node, or dir node for folded links).
- `subtreeMaxMtime` already excludes `.buildDir` subtrees from parents (`StorageTreeBuilder.swift:133`) — use it as the project's "last touched".
- `CleanupCategory` `Cleanup.swift:3`, `SafetyTier` `:7`, `DeleteMode` `:11`, `SizeProvenance` `:24`, `OwnerApp` `:42`, `CleanupItem` `:54` (init `:81`, defaults for optional fields), `CleanupSet` `:110`, `ClassifyOptions` `:128` (defaults 500 MB / 50 MB / 183 d, `:137-140`).
- `ReclaimAccumulator` `ReclaimAccumulator.swift:9` reads `linkGroupIndices` (indices into `tree.linkGroups` with ≥ 1 occurrence equal to or below `item.nodeID`, `:33-38`) — **you set them**.
- `DiskTools.log` `Sources/MonitorDiskTools/DiskTools.swift:7`.
- Test DSL `Tests/MonitorDiskToolsTests/Support/TreeFixture.swift:12` (`dir/file/small/link`, `.restricted(name)`, `build(root:_:scanDate:)` `:98`, default root `.home("/Users/test")` `:23`). Read-only.

## API to implement (plan §3.3; shape may grow, record final signatures)

```swift
BundleID.normalize(_ name: String) -> String?      // nil for TeamID-only names
BundleID.isAppleOwned(_ normalized: String) -> Bool
InstalledAppSet.build(home: String, mdfind: @Sendable () throws -> [String]) -> InstalledAppSet
  .owns(_ normalized: String) -> Bool ; .app(for normalized: String) -> OwnerApp?
SpotlightLastUsed.query(root: String, minBytes: UInt64) -> [String: Date]        // path → kMDItemLastUsedDate
Classifier(home: String, dataDirectories: [String], git: GitTracking, devTools: DevToolProbe,
           isUbiquitous: @Sendable (String) -> Bool)
  .classify(tree:installed:lastUsed:options:) -> ClassifyResult
  .resolve(_ result: ClassifyResult, found: [String: [String]]) -> CleanupSet
struct ClassifyResult { set: CleanupSet; unresolvedBundleIDs: Set<String> /* + pending leftovers, internal */ }
```
`GitTracking` / `DevToolProbe`: small protocols or closure structs with live impls (`Process`, precedent `Sources/MonitorSensors/Host/SleepAssertionSensor.swift:53`) and test fakes.

## Rules to encode (spec §6; decisions marked ★ are this brief's, record them)

- **Normalize** (§6.1): strip a leading team ID `^[A-Z0-9]{10}\.` **before** lowercasing (the pattern is uppercase — lowercasing first breaks it); lowercase; strip `group.`/`groups.`; strip `.plist`, `.savedstate`, `.binarycookies`. Contains `com.apple.` → Apple-owned. Result with no dot after stripping (`UBF8T346G9.Office` → `office`) → TeamID-only → never flagged (return nil).
- **Owned** (§6.2): any installed ID equals it, is a dot-boundary prefix or suffix of it (or vice versa), or shares its first two components (both need ≥ 2). `com.foo` vs `com.foobar` → not owned.
- **InstalledAppSet** (§6.2, no NSWorkspace step): `mdfind "kMDItemContentType == com.apple.application-bundle"` (injected) + `/Applications`, `~/Applications` two levels deep + Steam `steamapps/common`; drop hits under `~/.Trash`, `/Volumes`, `AppTranslocation`; read `CFBundleIdentifier` from `Contents/Info.plist`; add nested IDs from `Contents/Library/LoginItems`, `Contents/Helpers`, `Contents/PlugIns/*.appex`, iOS `Wrapper/*.app`. Never `lsregister -dump`.
- **Two-stage ownership** (plan W2b): `classify` keeps candidate leftovers whose IDs aren't owned out of `set.items`, lists their IDs in `unresolvedBundleIDs`, `set.ownershipResolved = false`. `resolve(found:)` (engine filled `found` from `StoragePlatform.appPaths`, `StorageServices.swift:9`) drops IDs with non-empty paths, adds the rest to Leftovers, `ownershipResolved = true`.
- **Categories** (§6.3), priority Developer > User Caches > Leftovers > Large & Old; classify the largest matching subtree only; an item never sits inside another item (nested de-dupe).
  - User Caches: children of `~/Library/Caches`, `~/Library/Logs`, `~/Library/Containers/*/Data/Library/Caches`, `~/.cache`; Safe, `.remove`, `keepParent = true`; owner via normalized ID → `installed.app(for:)`. Excluded: Apple-owned (allowlist `com.apple.dt.Xcode`), the system cache names listed in spec §6.3 row 1 (`CloudKit`, `com.apple.bird`, `GeoServices`, `PassKit`, `FamilyCircle`, `familycircled`, `GameKit`, `Animoji`, `askpermissiond`, `TemporaryItems`, `nsurlsessiond`, `akd`, `findmy*`, `containermanagerd`, `HomeKit`, `homed`, `ap.adprivacyd`).
  - Leftovers: normalized-ID entries in `~/Library/{Application Support,Caches,Containers,Group Containers,Preferences,Saved Application State,HTTPStorages,WebKit}`; not owned; not Apple-owned; age ★ `now − subtreeMaxMtime ≥ 90 d`; Review, `.trash`.
  - Large & Old: file nodes under non-hidden dirs of `~`, excluding `~/Library` (covers CloudStorage/Mobile Documents) and anything inside `.package` nodes; `≥ largeBytes`, or `≥ oldBytes` and `now − lastUsed ≥ oldAge`, `lastUsed = max(mtime, addedTime, Spotlight)`; Review; `isUbiquitous(path)` → `.evict`, else `.trash`.
  - Developer (fixed paths ★, keep the table in `CategoryRules.swift`; verify each against real tool docs, don't guess): DerivedData `~/Library/Developer/Xcode/DerivedData`, Homebrew `~/Library/Caches/Homebrew`, npm `~/.npm/_cacache`, yarn `~/Library/Caches/Yarn`, pnpm store, pip `~/Library/Caches/pip`, cargo `~/.cargo/registry/{cache,src}`, gradle `~/.gradle/caches`, CocoaPods `~/Library/Caches/CocoaPods`, JetBrains `~/Library/Caches/JetBrains` → Safe `.remove`. iOS/watchOS/tvOS/visionOS DeviceSupport: all but newest (★ by `mtime`) per platform → Review `.remove`. Unavailable simulators → Review `.simctl` only if `devTools.xcodeSelectOK` (`xcode-select -p` exit 0; a bare `xcrun`/`git` stub triggers the CLT install prompt). Xcode Archives older than 180 d → Review `.trash`. Docker `Docker.raw` → `.none`, note with the `docker system prune` hint.
  - Build dirs (`BuildDirRules`): node flagged `.buildDir` (names `node_modules`, `.build`, `target`, `Pods`, `build`, `cmake-build-*`) with its tool marker on the node (`npmLock|pnpmModules|yarnState`, `swiftpmWorkspaceState`, `cachedirTag`, `podsManifest`, `cmakeCache`); nearest ancestor with `.git` marker = project; not under a hidden dir of `~` nor `~/Library` nor `~/.cargo`; project `subtreeMaxMtime` older than 30 d; `git.trackedFiles(project, dir)` empty (`git -C <project> ls-files -z -- <dir>`; 5 s timeout, error, or `!xcodeSelectOK` → treat as tracked). Review `.remove`.
  - Trash: `~/.Trash` → category `.trash`, Review, `.remove`, `keepParent = true`; `set.trashBytes = tree.size(trash)` (nil when restricted/missing).
- **Own-data exclusion**: never an item if it is, contains, or is inside `dev.telltale*`, `dev.warden*`, `dev.telltale-dev` (`App/Sources/Composition/AppEnvironment.swift:75`, `:80`; `scripts/run.sh:16`) or any injected `dataDirectories` entry (compare by path components, never string prefix).
- Ignored: `options.ignoredPaths` contains the item path → `ignored = true`, item kept.
- Item fields: `id` sequential from 0 in a deterministic order (category, then path); `parentID = nil` ★ (group rows per owner are a W3a/W4b presentation concern; record as a plan gap); `nodeID`, `identity = tree.identity(node)`; `allocBytes = tree.size(node) ?? 0`; `linkGroupIndices` = groups with an occurrence equal to or below `nodeID`; `privateBytesExcludingLinks = nil`, `sizeProvenance = .estimate` (W2a `PrivateSizer` fills them later); `runningApp = false` (engine sets it from `StoragePlatform.runningBundleIDs`); restricted nodes never become items.
- **SpotlightLastUsed**: one scoped `MDQuery` (`CoreServices`) `kMDItemFSSize > minBytes` under `root`, synchronous on the caller's queue; returns path → `kMDItemLastUsedDate`. No per-file `MDItemCreate`.
- Linking `CoreServices`: if not importable from `MonitorDiskTools`, escalate (Package.swift is W1's).

## Tasks (commit per task, prefix `feat(storage-classify):`)

- [ ] T1 `BundleID` + `BundleIDTests`. Accept: table green.
- [ ] T2 `InstalledAppSet` + `InstalledAppsTests` (temp dir with fake `.app` bundles + injected `mdfind`). Accept: green.
- [ ] T3 `CategoryRules`, `DevToolProbe`, `GitTracking` (live + fakes).
- [ ] T4 `Classifier.classify` / `.resolve` + `ClassifierTests`. Accept: green; perf note.
- [ ] T5 `BuildDirRules` + `BuildDirTests` (fake `GitTracking`).
- [ ] T6 `SpotlightLastUsed` (no unit test; run once against `~` from a scratch test or the probe, record the count in progress).
- [ ] T7 Break-check + gate.

## Tests (each catches a named bug; table-driven; exact; deterministic — inject `now`, fakes for git/devtools/mdfind/isUbiquitous)

Trees via `TreeFixture.build` with root `.home("/Users/test")` and `home: "/Users/test"`.
- `BundleIDTests` table (spec §8): `group.com.apple.VoiceMemos.shared`, `74J34U3R6X.com.apple.iWork`, `243LU875E5.groups.com.apple.podcasts` → Apple; `UBF8T346G9.Office` → nil; `com.foo.app.widgetextension`, `com.foo.App.savedState`, `com.foo.plist` → expected normalized — bug: Apple group containers flagged / team-ID strip broken by lowercasing.
- `ClassifierTests`:
  - ownership table: equal, prefix, suffix, vendor (first two components), `com.foo` vs `com.foobar`, TeamID-only — bug: installed app's data offered.
  - app found **only** via `resolve(found:)` → not in Leftovers; unresolved and not found → in Leftovers, `ownershipResolved == true` — bug: helper-only/odd-location apps lose data.
  - leftovers at 89 d vs 91 d (injected `now`) — bug: off-by-one age gate.
  - own data: `Application Support/dev.warden`, `Caches/dev.telltale-dev/<wt>`, injected staging dir → never items (incl. a parent dir that contains one); `Caches/com.apple.dt.Xcode` is an item — bug: deleting our store/staging.
  - Large & Old table: exactly 500 MB recent → item; 499.99 MB recent → none; 50 MB + 183 d → item; 50 MB old mtime but recent `addedTime` → none; file under `~/Library` / hidden dir / inside `.app` → none; ubiquitous → `.evict`, else `.trash` — bug: trashing an iCloud file instead of evicting.
  - priority + nesting: `node_modules` inside a leftover dir appears once (in the higher-priority category) — bug: double count/delete.
  - ignored round-trip: path in `ignoredPaths` → `ignored == true`, still present; removed → `false` — bug: unignore impossible.
  - DeviceSupport: 3 iOS versions → the 2 older are items, newest not — bug: deleting the only support files.
  - `linkGroupIndices`: item containing one of two links of a group lists that group index — bug: reclaim double-count/phantom (feeds `ReclaimAccumulator`).
- `BuildDirTests` table: `.git` ancestor + marker + 30 d + untracked → item; missing marker / no `.git` / under `~/Library` or `~/.cargo` / project touched 10 d ago / tracked files / git timeout → none — bug: tracked `build/` deleted.
- `InstalledAppsTests`: hits under `~/.Trash`, `/Volumes`, AppTranslocation dropped; nested `.appex` ID added.
- Break-check: flip one ownership rule (e.g. drop the suffix check) → red; revert. Quote both runs.
- Perf (advisory): classify a ~180k-node synthetic tree, report ms (target < 50 ms).

## Gates

- Iterate: `scripts/test.sh ClassifierTests` etc. (rerun only failed + touched suites).
- Merge gate: `scripts/ci.sh ClassifierTests BundleIDTests InstalledAppsTests BuildDirTests` → `ci.sh: OK`; quote it. Also `scripts/build.sh` green (part of ci.sh).

## Rules

- Edit/Write tools only for file edits (no sed/heredoc/python). Bash for reading/searching/building.
- No `@unchecked`, no `as any`/lint disables, no swallowed errors (log via `DiskTools.log` and fail closed). No AppKit in `MonitorDiskTools`.
- Comments explain why, not what. No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines: pipe through `tail`/`grep`.
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefix `feat(storage-classify):`; message ends with
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W2b.md`: Plan / Done (hashes) / Next / Interface deltas (final signatures with file:line — W3b codes against these) / ★ decisions / Requests / Not verified / Blockers.
- Don't merge; don't run Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, perf, interface deltas, not verified.
