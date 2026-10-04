# W2b — classifier progress

Agent: Claude Opus 5.5. Worktree `/Users/arturvorokov/Documents/Projects/telltale-storage-w2b`, branch `ws/storage-w2b` (from `feat/storage` c0be58c).

## Plan
T1 BundleID · T2 InstalledAppSet · T3 CategoryRules/DevToolProbe/GitTracking · T4 Classifier · T5 BuildDirRules · T6 SpotlightLastUsed · T7 break-check + gate

## Done
- T1 0e71ae4 BundleID; T2 fe9a1e1 InstalledAppSet + ProcessRun; T3-T5 Classifier + rules + probes + tests (commit after fe9a1e1); T6 + progress + gate (final commit).
- Break-checks (reverted): `BundleID` lowercase-before-team-strip → BundleIDTests 3 issues; drop suffix ownership check → InstalledAppsTests 1 issue.
- Perf: classify of a 182k-node synthetic tree: 4.5 ms release (best of 5), 225 ms debug build (advisory target < 50 ms met in release).
- Spotlight (real `~`, `kMDItemFSSize > 50 MB && kMDItemLastUsedDate == *`): 7 hits in 0.24 s (unfiltered size-only query: 873 hits, 7 with a date).

## Interface deltas (all `public` in `MonitorDiskTools`, `Sources/MonitorDiskTools/Classify/`)
- `BundleID.normalize(_:) -> String?`, `.isAppleOwned(_:) -> Bool` (BundleID.swift)
- `InstalledAppSet.build(home:mdfind:)`, `.liveMdfind`, `init(ids: [String: OwnerApp])`, `.owns(_:)`, `.app(for:)` (InstalledAppSet.swift)
- `SpotlightLastUsed.query(root:minBytes:) -> [String: Date]` (SpotlightLastUsed.swift); imports `CoreServices` (links without Package.swift change)
- `protocol GitTracking { hasTrackedFiles(project:dir:) -> Bool }` (fail-closed, not `trackedFiles` array), `LiveGitTracking()`
- `protocol DevToolProbe { var xcodeSelectOK: Bool; func unavailableSimulatorUDIDs() -> [String] }`, `LiveDevToolProbe()`
- `Classifier(home:dataDirectories:git:devTools:isUbiquitous:)`, `.classify(tree:installed:lastUsed:options:) -> ClassifyResult`, `.resolve(_:found:) -> CleanupSet`
- `ClassifyResult { set, unresolvedBundleIDs }`. `unresolvedBundleIDs` are normalized (lowercase) IDs: pass them to `appPaths` and key `found` by the same strings.
- Unavailable-simulator row: `nodeID == nil`, `identity == nil`, `path` = `~/Library/Developer/CoreSimulator/Devices`, `allocBytes` = sum of the unavailable device dirs, `mode == .simctl`. Cleaner must not require a node for `.simctl`.
- Docker row: `mode == .none`, note carries the prune hint; selection UI must not allow it.
- `classify` always returns `ownershipResolved == false`, even when `unresolvedBundleIDs` is empty: call `resolve` regardless. `resolve` re-sequences ids (pending leftovers inserted in (category, path) order); ids from `classify` are not stable across `resolve`.

## ★ decisions
- Nesting: outermost item wins (ids grow with depth, walk by node id); same node in several categories goes to the highest priority (Trash > Developer > User Caches > Leftovers > Large & Old). Brief's "Developer beats a surrounding leftover" can't occur: build dirs only count outside `~/Library` and hidden dirs, where no Leftover/User Cache/Trash item can sit. Large files inside a build dir are therefore not separate items (test `largeFileInsideBuildDirIsNotASecondItem`).
- Caches of an uninstalled app's container: the container is the Leftover; its `Data/Library/Caches` children are not separate User Caches rows. If `appPaths` later finds the app, those caches are not re-offered until the next classify.
- Leftover candidates that are also User Caches candidates (`~/Library/Caches/<id>`) stay User Caches (Safe); they are not put into `unresolvedBundleIDs`.
- System cache name list also excludes Leftovers (e.g. `ap.adprivacyd` has a dot).
- Zero-byte and restricted nodes never become items.
- `keepParent` only for directories (cache children, Trash).
- Leftover `lastUsed` = `subtreeMaxMtime`; Large & Old `lastUsed` = max(mtime, addedTime, Spotlight).
- Large & Old: `now - lastUsed >= oldAge` (183 d inclusive); leftovers `>= 90 d`; build-dir project `>= 30 d`; archives `>= 180 d`.
- Hidden = `.hidden` flag or name starting with `.`.
- Developer paths added beyond the brief's list: `~/Library/pnpm/store` (verified with `pnpm store path`) and `~/Library/Caches/pnpm`. Docker also at `~/.docker/desktop/vms/0/data/Docker.raw`. Device-support platforms limited to iOS/watchOS/tvOS/visionOS.
- Build dir marker map in `BuildDirRules.requiredMarkers`: node_modules→npmLock|pnpmModules|yarnState, .build→swiftpmWorkspaceState, target→cachedirTag, Pods→podsManifest, build→cmakeCache|cachedirTag, cmake-build-*→cmakeCache.
- Own data: any node named `dev.telltale*` / `dev.warden*` anywhere in the tree, plus injected `dataDirectories` (resolved by path components via `tree.lookup`); items that are, contain or sit inside one are dropped.
- `parentID` stays nil (per-app grouping is W3a's job); `runningApp` false (W3b).
- Plan gap: per-owner group rows are not produced by the classifier.

## Requests
- None. `ProcessRun` (internal, `Classify/ProcessRun.swift`) is local; W2c has its own process helpers.

## Not verified
- `LiveDevToolProbe.unavailableSimulatorUDIDs` against a machine that has unavailable simulators (0 here; JSON shape parsed from memory of `simctl list -j`, not unit tested).
- `LiveGitTracking` timeout path (5 s) not exercised; only tracked / untracked / non-repo.
- Real-home end-to-end classification (needs W2a scanner + W3b engine).
- Release-mode perf measured via an ad-hoc `swift test -c release -Xswiftc -enable-testing` run, scratch test deleted.

## Blockers
- None.
