# Storage & Cleanup page — design

Date: 2026-09-24 · Status: approved design + review round 1 applied, pre-plan

## 1. Goal

Add a **Storage** page to the dashboard that shows where disk space goes (analyzer-first) and lets the user reclaim space from curated categories: user caches, leftovers of deleted apps, large & old files, developer junk, Trash. The tool must be fast: a 1M-entry home scans in ~5 s warm, and every interaction stays under a frame.

Non-goals (v1): root/system-area cleanup, background or periodic scanning, notifications, duplicate finding, Time Machine snapshots, Mail/iOS backups, cleanup history UI, incremental rescan.

## 2. Decisions

### 2.1 Interview

| Topic | Decision |
|---|---|
| Core job | Analyzer-first (space map), cleanup categories alongside |
| Placement | New sidebar page `Storage`, System section, next to Disk. Disk stays live telemetry |
| Scan scope | Default `~`; any folder or mounted volume via picker. Cleanup mode only for a `~` root (§4.4) |
| Permissions | Detect Full Disk Access (FDA); banner + "Open System Settings" if missing; scan still runs, unreadable dirs shown as restricted |
| Signing | Apple Development cert via local xcconfig so the FDA grant survives rebuilds (§3.7) |
| Delete mode | Regenerable data: permanent remove. User data: Move to Trash with undo |
| Categories | User Caches, Leftovers, Large & Old, Developer, Trash |
| Scan timing | Manual only; last result cached and shown instantly with timestamp |
| In-use items | `In use` badge, excluded from default selection, listed in confirm |
| Guardrails | Hard denylist + fd-relative deletion enforced in the cleaner; confirm dialog for every clean |
| Visualization | Treemap + drill-down table, synced hover |
| Dev junk | Global tool caches + project build dirs in stale git projects |
| Large & Old | ≥ 500 MB, or ≥ 50 MB and unused 6 months; thresholds adjustable in page; per-item ignore list |
| Preselection | Only `Safe` tier preselected |
| Integration | Sidebar trailing value; popover Disk section "Free up space…" link |

### 2.2 Implementation defaults

- Space Map sizes are allocated bytes; hard links count once (§5.5).
- Cleanup sizes are **private bytes** (`ATTR_CMNEXT_PRIVATESIZE`): bytes actually freed on delete, excluding clone-shared and snapshot-held blocks. Shown without "≈" (§5.7).
- Docker: `Docker.raw` size shown as info only with a `docker system prune` hint; never deleted.
- After cleaning, the tree updates in place; no automatic rescan.
- Rescan keeps the previous result visible with a progress overlay.
- Space Map children table uses the same capped set as the treemap.

### 2.3 Resolved open questions

- Team ID lives in gitignored `Local.xcconfig`; absent file → ad-hoc build (§3.7).
- Developer additions: CocoaPods and JetBrains caches. Go module cache and Android SDK/AVDs excluded (§10).
- Stat strip tiles always present; Trash shows `Empty` at 0 B, `—` when unreadable; Reclaimable `—` before first scan.

## 3. Architecture

### 3.1 Targets and dependencies

- **New SPM target `MonitorDiskTools`** (name avoids confusion with `MonitorStore`): lister, scanner, classifier, cleaner, scan cache. Depends on `MonitorModel` only. Not a `Sensor`; stays outside `SamplingEngine`.
- ARCH §2 target graph gains `MonitorDiskTools → MonitorModel`. Add it to the "UI targets never import …" list (ARCH:157). `MonitorLive` must not depend on it.
- **Composition**: `MonitorRuntime` imports `MonitorDiskTools`; `TelltaleRuntime` exposes `storage: StorageModel` and `storageActions: StorageActions`. App never imports `MonitorDiskTools` (App's allowed imports, `project.yml:35-36`). `MockPipeline` supplies canned actions that never touch disk.
- AppKit-bound pieces (reveal in Finder, open FDA settings pane, app icons) live in `StorageActionsLive` in `MonitorScreens/Shell/`, next to `ProcessActionsLive.swift`. Runtime and DiskTools never import AppKit; anything they need from AppKit is injected as a `@Sendable` closure.

### 3.2 Model types (`MonitorModel`, all need ICR 016)

`StorageTree` (immutable, Sendable, struct-of-arrays snapshot), `StorageNodeID` (`Int32`), `ScanEvent`, `ScanProgress`, `ScanFailure`, `CleanupItem`, `CleanupCategory`, `SafetyTier` (`safe` / `review`), `DeleteMode` (`remove` / `trash` / `evict` / `simctl` / `none`), `CleanEvent`, `CleanReport`, `UndoRecord`, `StorageSummary`, `StorageActions`, `DashboardPage.storage`.

### 3.3 Data flow

- `StorageActions` — `Sendable` struct of `@MainActor @Sendable` closures, same shape as `ProcessActions`, with `.noop` and mock variants:
  - `scan(root:) -> AsyncStream<ScanEvent>` — `.progress(ScanProgress)`, `.partial(StorageTree)`, `.finished(StorageTree)`, `.failed(ScanFailure)`
  - `cancelScan()`
  - `clean(items:) -> AsyncStream<CleanEvent>` — `.detached(id, bytes)`, `.skipped(id, reason)`, `.freed(bytes)`, `.finished(CleanReport)`
  - `undo(UndoRecord) -> AsyncStream<CleanEvent>`
  - `ignore(path:)`, `revealInFinder(path:)`, `openFDASettings()`, `emptyTrash()`
- `StorageModel` (`@MainActor @Observable`, `MonitorLive`) consumes the streams and owns the scan/clean tasks and undo records. Split into sub-objects so views observe only what they read:
  - `ScanProgressState` — files, bytes, current path; one struct assignment per tick; read only by the progress card.
  - `SpaceMapState` — tree reference, focus node, breadcrumb, cached layouts.
  - `CleanupState` — items, checked `Set<Int32>`, running selected bytes/count, sort, expansion.
  - `HoverState` — `hoveredID` only.
- Tree swaps are a single reference assignment; views compare `tree.version`, never contents.

### 3.4 Lifetimes

- Page switch: scan and clean keep running; undo records survive.
- Window close: scan cancelled (no background scanning). A running clean finishes its current item, then stops; staged items still get deleted by the background worker (§7.2).
- Window closed: `StorageTree` released; only `StorageSummary` (reclaimable, scan date, trash size) kept for sidebar/popover. Page appear reloads from cache off-main. Keeps within SPEC UI-closed RSS < 80 MB. Add a scan-memory row to ARCH §7.
- Undo records persist on disk until the Trash item is gone or 7 days pass (§7.5).

### 3.5 Concurrency

- Scanner: fixed pool of N `Thread`s at `.userInitiated` QoS, N = performance-core count (`hw.perflevel0.physicalcpu`), cap 8. Never a GCD concurrent queue (blocking `getattrlistbulk` causes thread explosion). Never `.background` QoS (measured 3.6× slower).
- Workers pull from one LIFO work stack guarded by `OSAllocatedUnfairLock` (ARCH §4 Box pattern; no `@unchecked`, `ci.sh:40`). Cancellation = atomic flag checked per pop.
- Classifier, private-size pass, Spotlight query, installed-app scan: one serial `DispatchQueue` at `.utility`, run concurrently with or right after the scan.
- Cleaner: detach step serial; background delete worker runs up to 4 `removefile` calls in parallel.
- Other sensors keep sampling during a scan: pausing would record a History gap (ARCH §3) and the sampler cost is small next to an I/O-bound scan.

### 3.6 Navigation and records

- `DashboardPage.storage`, System section. ICR `docs/icr/016-<stream>-storage-page.md` covers the enum case and every new MonitorModel type.
- Exhaustive switches to update in one `model:` commit: `Navigation.swift`, `DashboardRoot.swift`, `Sidebar.swift`, `Sampling.swift`, `PageHeader.swift:142`, `TTIcon.swift:35,105` (new glyph, DESIGN §1.4), `ScreenCatalog` (auto entry → snapshot golden), `LaunchOptions` (`--open-dashboard storage`), `telltale-probe/Options.swift`, `UIVisibilityTests`, `ShellSnapshotTests`.
- `Sampling.swift`: Storage demand `.none` (`VolumeSensor` has no `requires`, runs every 10 s interactive). Free refreshes within ≤ 10 s after a clean; no immediate-sample API.
- Doc edits: SPEC ruling adding cleanup to v1 + Categories, Data sources (getattrlistbulk, Spotlight, mdfind, FDA probe), Actions, artboard list. ARCH §2, §4 table, §5.10/5.11, §7 budgets, §8 test rows, §11. DESIGN new §3.16 Storage screen, §2.28 treemap "smaller items" rule, §3.12 toast, §3.1 popover link copy.

### 3.7 Signing

- Move `CODE_SIGN_IDENTITY "-"` / `CODE_SIGN_STYLE Manual` out of `project.yml:11-12` `settings.base` (it overrides config files) into committed `Signing.xcconfig`, which ends with `#include? "Local.xcconfig"`.
- Gitignored `Local.xcconfig` sets `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY = Apple Development`, `CODE_SIGN_STYLE = Automatic`. Commit `Local.xcconfig.example`.
- `scripts/install.sh:40` currently ad-hoc re-signs every install, wiping the cert and FDA grant. Change: re-sign with the identity from `Local.xcconfig` when present, else ad-hoc as today.

### 3.8 Cache location

`AppEnvironment.dataDirectory/storage-scan.bin` (honors `TELLTALE_DATA_DIR`, keeps worktrees and tests isolated). One file per scan root, keyed by volume UUID + root path.

## 4. Page layout

Grid per DESIGN §3.0 (padding 20, gap 12, `grid3`). Artboards at 1100×720 (min window, `ShellStyle.dashboardMinSize`; ~840 pt content width) and 1280×860.

### 4.1 Chrome

- **Header trailing**: scan root chip (`~ ▾`: Home / Choose Folder… / mounted volumes) · `Scanned 2 h ago` (DESIGN §5.8, injected `now`) · `Scan` / `Rescan` (becomes `Cancel` while scanning). Volume list excludes `MNT_DONTBROWSE` / `MNT_SNAPSHOT` mounts; "Macintosh HD" maps to `/System/Volumes/Data`.
- **FDA banner** (only without FDA): "Some folders unreadable. Grant Full Disk Access for complete results." + `Open System Settings`. Dismissible per session.
- **Stat strip**: Capacity · Used · Free (`ShellFormat.freeSpace`) · Purgeable · Reclaimable · Trash. Formats: DESIGN §5.3 headline style. At 1100 width, Purgeable drops first.
- **Mode switch** (`TTSegmented`): `Space Map` (default) | `Cleanup`.

### 4.2 Space Map

- Breadcrumb `~ › Library › Caches`.
- Treemap card (2 cols) + children table card (1 col: Name, Size, %; Items column drops at 1100 width). Hover synced.
- Tile set per node: children sorted by size; cut at < 0.5% of parent **or** laid-out tile < ~24×16 pt; the remainder merges into one "N smaller items" tile/row. Typical 30–80 tiles, hard cap 200.
- Restricted dirs: hatched tile, size `—`, tooltip "Needs Full Disk Access". Sealed system volume (boot-volume scans): one opaque node.
- Row/tile menu: Reveal in Finder · Move to Trash… · Ignore. Trash disabled with reason tooltip on denylisted paths.
- Keyboard: arrows move hover/selection, Return drills in, ⌘[ / Backspace goes up. Tiles expose accessibility elements "{name}, {size}, {share}%".

### 4.3 Cleanup

- Left card: category list (User Caches · Leftovers · Large & Old · Developer · Trash), each with total, selected, tier mix.
- Right card: table of the category's items — checkbox · icon + name · size · tier badge · `In use` badge · last used. Grouped per owning app as child rows, children only when expanded. Large & Old card header has threshold `TTSegmented`.
- Sticky footer: `Selected 14.2 GB · 37 items` + `Clean…`; keyboard-reachable. Space toggles checkbox.
- Materialized iCloud files in Large & Old offer `Remove Download` instead of Trash.

### 4.4 Scan roots outside `~`

Space Map + Move to Trash only; Cleanup mode disabled with a caption explaining why.

### 4.5 States

| State | UI |
|---|---|
| Never scanned | `TTEmptyState` + Scan button |
| Scanning, no prior result | Progress card (files, bytes, current path middle-truncated, Cancel) + partial treemap of root children, updated 2–4 Hz |
| Rescanning | Previous result visible, progress overlay |
| Cached result | Header + stat strip immediately; map when cache decoded (< 100 ms) |
| Volume removed mid-scan | Empty state "Volume was removed"; partial result never cached |
| Root error | Empty state with reason |

### 4.6 Outside the page

- `Sidebar.value` signature extended to take `StorageSummary` (currently static over `LiveModel`, `Sidebar.swift:52`): `12 GB reclaimable` after a scan, else free space.
- `ShellContext` gains `storage` + `storageActions`; `@Entry storageActions` in `EnvironmentValues+Telltale.swift`.
- Popover Disk section: `Free up space…` link opens the Storage page.

### 4.7 UIKit work

- **`TTSpaceMap`** (new, generic): tiles `{id: Int32, value, label, kind: normal/smaller/restricted}`; whole map drawn in one `Canvas` (precedent `TTChartCanvas`, `TTAreaChart.swift:78`); labels only where they fit; one `onContinuousHover` hit-testing cached rects; hover highlight as a separate overlay layer reading only `HoverState`; one overlay tooltip; restricted hatch as one cached pattern; tiles keyed by node id; no animation on drill-down; `.accessibilityChildren`. Existing `TTTreemap` (typed to `AppShare`, per-tile SwiftUI views, index identity) stays for its current use.
- **`TreemapLayout`**: accept presorted input (skip re-sort, `TreemapLayout.swift:41`); track row min/max incrementally so each step is O(1) (today O(k²), `:52-77`). Layout cached per (node id, size).
- **`TTTable`**: add `hover: Binding<ID?>`, include `isHovered` in row equality (`:282-286`) so a hover change redraws two rows. Cleanup uses `sortsRows: false` with model-owned sorted lines cached per (category, sort, expansion) (precedent `.processes`, `:350`). Checked state is part of the row value.
- **Table checkbox cell** (none exists; DESIGN §2.29 is Settings-only).
- **`TTToast`**: second action (`Show`, `Empty Trash`), lifetime 10 s when Undo present (`TTToast.swift:10-23`).
- **Confirm dialog**: multi-line message with capped in-use list ("+N more") (`ConfirmDialogHost.swift:7-13`).
- **Icons**: owner bundle paths resolved during classification; icons warmed off-main, keyed by bundle ID, letter tile until ready; per-type icons for files/folders.

## 5. Scanner

### 5.1 Engine

`getattrlistbulk` walker behind a `DirectoryLister` protocol. Measured (M1 Max, 555k entries, warm): FileManager enumerator 12–19 s; bulk 1 thread 9.9 s; 8 threads 2.2 s (250k entries/s); 16 threads no gain; buffer size (32 KB–1 MB) irrelevant. Time is I/O latency, so parallelism is the lever.

- Attributes: `ATTR_CMN_RETURNED_ATTRS`, `ERROR`, `NAME`, `OBJTYPE`, `FILEID`, `MODTIME`, `ADDEDTIME`, `FLAGS`; dir `ATTR_DIR_MOUNTSTATUS`; file `ATTR_FILE_LINKCOUNT`, `ATTR_FILE_ALLOCSIZE`. No `DEVID`.
- `FSOPT_PACK_INVAL_ATTRS` does **not** give a fixed layout (dir entries omit file attrs and vice versa): the parser walks the returned-attributes mask per entry.
- Directory fds opened with `openat(parentFd, name, O_RDONLY|O_DIRECTORY|O_NOFOLLOW)`; path strings built only for kept nodes.
- `FileManager` fallback lister exists for tests (`InMemoryLister` is the main test double); kernel emulates bulk on non-native filesystems, so production fallback is not expected.

### 5.2 Walk rules

- Each worker calls `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)`.
- Never descend into a dir with `SF_DATALESS` in `ATTR_CMN_FLAGS`; dataless files count allocated bytes only, tagged `cloud`.
- Skip dirs with `DIR_MNTSTATUS_MNTPOINT` or `DIR_MNTSTATUS_TRIGGER` (mount points, autofs triggers such as `/System/Volumes/Data/home`). One `fstatfs` on the root; no per-entry device check.
- Never follow symlinks.
- Skip `.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`.
- Packages (`.app`, `.photoslibrary`, `.musiclibrary`, `.fcpbundle`, `.xcarchive`, `.pvm`, `.utm`, other bundle dirs) are walked for size but presented as leaf nodes.
- Unreadable dir → `restricted` node, size nil.
- Unmount notification for the scanned volume → cancel, `.failed(.volumeRemoved)`, no cache write. Worker dir fds closed promptly so Eject from the Disk page isn't blocked longer than one listing.

### 5.3 Arena

- A dir's node is allocated when its parent is listed; each listing's children are committed in one batch, so children are contiguous (`firstChild` + `childCount`, `Int32`) and every parent index is lower than its children's. Size rollup = one reverse pass.
- Struct-of-arrays: parent, firstChild, childCount, allocBytes, smallBytes, smallCount, mtime, subtreeMaxMtime, addedTime, flags, markerMask, nameOffset/nameLength into one pooled UTF-8 byte buffer. ~45 B + ~25 B name per node.
- Nodes kept for: all dirs, files ≥ 1 MB, and all direct children of the `~/Library` subdirs scanned by §6 (incl. small plists). Other small files fold into the parent's `smallBytes` / `smallCount`. 1M-file home ≈ 180k nodes ≈ 13 MB.
- Children stored sorted by size descending after rollup, with prefix sums, so the tile cutoff is a binary search.
- Per-dir facts recorded during listing (raw name-byte compare, no extra syscalls): `markerMask` (`.git`, `package.json`, `Package.swift`, `Cargo.toml`, `Podfile`, gradle/CMake files, `CACHEDIR.TAG`, `CMakeCache.txt`, `workspace-state.json`, `.package-lock.json`, `.modules.yaml`, `.yarn-state.yml`, `Manifest.lock`) and `subtreeMaxMtime` (excluding build dirs).

### 5.4 Progressive results

Rollup snapshot at 2–4 Hz publishes root-children sizes and the current breadcrumb level as `.partial`. Biggest dirs visible within ~0.5 s. `.progress` ticks throttled to 10 Hz.

### 5.5 Hard links

Common (98k of 482k files in the benchmark tree: cargo `target/`, git worktrees). One global `(dev, inode)` set sharded 16 ways under `OSAllocatedUnfairLock`, touched only when link count > 1. Bytes credited after the scan to the lowest-depth path so sizes don't depend on thread timing. A cleanup candidate counts a hard-linked file as reclaimable only if all its links fall inside the deleted set.

### 5.6 Cache format

Fixed binary layout: header (magic, schema version, root path, volume UUID, scan date, FSEvents `lastEventId`, counts) followed by the raw arrays. Written to a temp file, then renamed. Read via `mmap`; decode off-main. Target < 100 ms for ~300k nodes. `lastEventId` stored now for a later staleness badge (§10).

### 5.7 Private-size pass

After the scan, a background pass fetches `ATTR_CMNEXT_PRIVATESIZE` for cleanup candidates only (all-entries cost 2.2× scan time; benchmark tree 57.0 GB private of 66.9 GB allocated). Cleanup totals update when it completes; until then they show allocated bytes with "≈".

### 5.8 Perf targets (advisory)

- 1M entries: ≤ 5 s warm, ≤ 15 s cold (cold is an estimate; needs `sudo purge` to measure).
- Drill-down derived state for a 10k-child node < 2 ms; frame < 16 ms.
- Cache load < 100 ms for ~300k nodes.
- Cleanup line build + diff for 10k items: advisory test; NSTableView-backed table only if it fails.
- `telltale-probe --scan <root>` bench prints entries, nodes, wall time, RSS.

## 6. Classification

Runs after the scan over the arena (milliseconds; thresholds changes re-run it). Classifies only the largest matching subtree, never its contents. Nested selections are de-duplicated so nothing is counted or deleted twice. Priority: Developer > User Caches > Leftovers > Large & Old.

### 6.1 Bundle-ID normalization

For any `~/Library` name: lowercase; strip a leading team ID (`^[A-Z0-9]{10}\.`); strip `group.` / `groups.` prefix; strip `.plist`, `.savedstate`, `.binarycookies`. Any result containing `com.apple.` is Apple-owned.

### 6.2 Installed-app set

Built on the utility queue during the scan:

- `mdfind "kMDItemContentType == com.apple.application-bundle"` (~0.1 s, 482 apps measured). Never `lsregister -dump` (13.5 s).
- Plus `/Applications` and `~/Applications` two levels deep (Setapp, JetBrains Toolbox, Chrome Apps) and Steam `steamapps/common`.
- Drop hits under `~/.Trash`, `/Volumes`, App Translocation.
- Add nested bundle IDs: `Contents/Library/LoginItems`, `Contents/Helpers`, `Contents/PlugIns/*.appex`, iOS-app inner bundles (`Wrapper/`).
- For still-unmatched candidates only: `NSWorkspace.urlsForApplications(withBundleIdentifier:)` (injected closure).

An ID is **owned** if any installed ID equals it, is a dot-boundary prefix/suffix of it, or shares its first two components (vendor). Names that are only `<TeamID>.<word>` are never flagged.

### 6.3 Categories

| Category / item | Source | Tier | Delete |
|---|---|---|---|
| User Caches | children of `~/Library/Caches`, `~/Library/Logs`, `~/Library/Containers/*/Data/Library/Caches`, `~/.cache`; owner via normalized ID → installed app. **Excluded**: Apple-owned (§6.1) and un-prefixed system caches (`CloudKit`, `com.apple.bird`, `GeoServices`, `PassKit`, `FamilyCircle`, `familycircled`, `GameKit`, `Animoji`, `askpermissiond`, `TemporaryItems`, `nsurlsessiond`, `akd`, `findmy*`, `containermanagerd`, `HomeKit`, `homed`, `ap.adprivacyd`), Telltale's own `dev.telltale*`. Apple allowlist: `com.apple.dt.Xcode` | Safe | remove (keep parent dir) |
| Leftovers | normalized-ID dirs/plists in `~/Library/{Application Support, Caches, Containers, Group Containers, Preferences, Saved Application State, HTTPStorages, WebKit}`; not owned (§6.2); not Apple-owned; `subtreeMaxMtime` older than 90 days | Review | trash |
| Large & Old | files under visible (non-hidden) dirs of `~`, excluding `~/Library` and `~/Library/CloudStorage`; excluding library/VM packages and `.app`. ≥ 500 MB, or ≥ 50 MB and last used ≥ 6 months, where last used = max(mtime, `ADDEDTIME`, Spotlight `kMDItemLastUsedDate`) | Review | trash; materialized iCloud files → evict (`evictUbiquitousItem`) |
| Dev: DerivedData, package caches (Homebrew, npm, yarn, pnpm, pip, cargo, gradle, CocoaPods), JetBrains caches | fixed paths | Safe | remove |
| Dev: iOS DeviceSupport (all but newest per platform) | fixed path | Review | remove |
| Dev: unavailable simulators | `xcrun simctl delete unavailable`, only if `xcode-select -p` succeeds (bare `xcrun` stub triggers install prompt) | Review | simctl |
| Dev: Xcode Archives older than 180 days | fixed path | Review | trash |
| Dev: project build dirs | `node_modules`, `.build`, `target`, `Pods`, `build`, `cmake-build-*` that: have a `.git` ancestor; are not under hidden dirs of `~` or under `~/Library`; contain their tool's marker (`CACHEDIR.TAG`, `CMakeCache.txt`, `.build/workspace-state.json`, `node_modules/.package-lock.json` / `.modules.yaml` / `.yarn-state.yml`, `Pods/Manifest.lock`); project `subtreeMaxMtime` > 30 days; contain no git-tracked files (`git ls-files` in the project, candidates only) | Review | remove |
| Dev: Docker | `Docker.raw` size + `docker system prune` hint | — | none |
| Trash | `~/.Trash` | Review | remove (empty) |

### 6.4 Spotlight last-used

One scoped `MDQuery` for `kMDItemFSSize > 50 MB` under the scan root (~0.2–0.35 s measured), run concurrently with the scan. No per-file `MDItemCreate`. Most files lack the attribute (398 of 402 here), hence the max() rule above.

### 6.5 In-use detection

At list build: `NSWorkspace.runningApplications` bundle IDs (cheap badge). At Clean: one pass over this user's processes (`proc_listpids`, then per pid `proc_pidinfo` open vnode paths, cwd, executable path) marks any item containing one of those paths `In use`; catches agents and CLI tools (brew, npm, dev servers) and caches without bundle IDs (`Arc`, `Google`). Estimated 100–300 ms, unmeasured. In-use Safe items get unticked; confirm offers "Quit X first" for GUI apps.

### 6.6 Ignore list and thresholds

`SettingsStore` keys `storage.ignoredPaths`, `storage.largeThreshold`, `storage.oldThreshold` (existing style, e.g. `units.temperature`), backed by injected defaults so `InMemoryDefaults` works. Ignored items hidden from Cleanup, visible in Space Map; `Show ignored` toggle.

## 7. Cleanup

### 7.1 Flow

1. `Clean…` pressed.
2. In-use recheck (§6.5); newly in-use items unticked with a notice.
3. Confirm via `ConfirmDialogHost` (`await confirm(...)`): title `Clean 14.2 GB?`; message lines "Delete permanently: X (caches, build data)", "Move to Trash: Y (leftovers, large files)", "Remove downloads: Z (iCloud)", capped in-use list; `Clean` (destructive) / `Cancel`.
4. Detach phase: items detached one by one (instant renames); footer `Cleaning 12/37…`; UI tree and totals update as each `.detached` arrives. Cancel stops further detaching; detached items are committed.
5. Background delete worker frees staged items; footer shows `Freeing…` until done.
6. Toast: `Freed X · Moved Y to Trash` + `Empty Trash` (when Y > 0) + `Show` (skip reasons) + `Undo` (trash items, 10 s). Trashed bytes are never reported as freed.

### 7.2 Staging pipeline (remove mode)

- Staging dir `dataDirectory/staging/` (created on demand, `0700`). Remove mode only runs in Cleanup, which only runs on `~`, so staging is always on the item's volume; if `dev` of staging ≠ item's `dev`, fall back to direct `removefile` after the same identity check.
- Detach: `renameatx_np(parentFd, name, stagingFd, uniqueName, RENAME_EXCL | RENAME_NOFOLLOW_ANY)`, then `fstatat(AT_SYMLINK_NOFOLLOW)` on the staged entry; if dev/inode/type differ from the scan, rename back and skip "changed since scan".
- Delete: worker runs up to 4 `removefileat`/`removefile` in parallel with `REMOVEFILE_RECURSIVE` (+ `REMOVEFILE_RECURSIVE_SLIM` if available on 14 — spike), `removefile_state` for cancel and error callback. On `EACCES` inside a staged tree owned by the user: add `u+w` and retry. Never `REMOVEFILE_ALLOW_LONG_PATHS` (changes cwd, not thread-safe).
- Cache dirs ("keep parent"): each child detached individually; parent stays.
- Launch sweep: any leftover staging dir from a crash is deleted by the worker at app start.
- Freed bytes = sum of private sizes of items fully removed. Volume free-space delta shown only as a side note. Files held open by a process free only when it exits.

### 7.3 Other primitives

- `trash`: `FileManager.trashItem(at:resultingItemURL:)` after the same fd-based identity check; resulting URL recorded for undo. Volumes without a Trash (SMB, some exFAT) → skip with reason; never fall back to permanent delete.
- `evict`: `FileManager.evictUbiquitousItem(at:)`; iCloud copy stays.
- `simctl`: `xcrun simctl delete unavailable` via `Process`, 60 s timeout.
- Empty Trash: remove mode over `~/.Trash` children; locked (`uchg`) files owned by the user get the flag cleared, then retried.
- Per-item errors collected into `CleanReport`, never thrown. Vanished before detach: remove mode = success with 0 bytes; trash mode = 0 bytes, noted.

### 7.4 Guardrails (enforced in `MonitorDiskTools`, not only UI)

- All filesystem steps fd-relative: each path component opened with `O_NOFOLLOW` (`O_NOFOLLOW_ANY` for full paths); `RESOLVE_BENEATH` if macOS 14 honors it (spike), else `NOFOLLOW_ANY`. No `realpath` + path-string deletion.
- **Denylist** as a precomputed set of `(dev, inode)` pairs, built at clean time: `/`, `~`, `~/Library`, every direct child of `~/Library`, `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/private`, `/opt/homebrew`, `/usr/local`, `~/Library/Keychains`, `~/Library/Mobile Documents`, `~/Library/CloudStorage`, `~/Library/Mail`, `~/Library/Application Support/MobileSync`, the scan root. A target is refused if it **is** or **contains** a denylisted entry (`contains` checked from scan data: denylisted inodes' ancestry). Immune to case and Unicode normalization differences.
- Allowed targets: inside `~` (Cleanup) or inside the chosen scan root (Space Map trash only).
- Injected permitted root: tests pass a temp dir; cleaner refuses anything outside it.
- No root, no `sudo`, no privileged helper. `EPERM` → skip with reason.
- `os_log` category `storage`: one line per detached/trashed/evicted path with bytes and mode.

### 7.5 Undo

- `UndoRecord` per clean (trash items only) persisted in `dataDirectory/storage-undo.json`: original path, trash URL, dev/inode.
- Restore via `renameatx_np(RENAME_EXCL)`; missing parent dirs recreated; if the original path is taken → restore as `name (restored)`; if the item left the Trash → reported, not silent.
- Records pruned when the Trash item is gone or after 7 days. Toast Undo covers the latest clean; older records have no UI in v1.

## 8. Testing

Suites run via `scripts/test.sh <Suite>`.

- New `MonitorDiskToolsTests`:
  - `ScannerTests` (`InMemoryLister`): sizes, hard-link dedupe + deterministic crediting, small-file folding, kept `~/Library` children, marker mask, subtreeMaxMtime, restricted nodes, dataless dirs not entered, mount-point/trigger skip, package leafs, contiguous children, sort + prefix sums, cancel, volume-removed failure.
  - `BulkParserTests`: returned-attrs mask walking on recorded buffers (dir vs file layouts).
  - `ClassifierTests`: bundle-ID normalization table (incl. `group.com.apple.VoiceMemos.shared`, `74J34U3R6X.com.apple.iWork`, `243LU875E5.groups.com.apple.podcasts`, `UBF8T346G9.Office`, `*.widgetextension`), ownership rules, Apple-cache exclusions, 90-day leftover age, Large & Old scope and package exclusion, last-used max rule, build-dir markers/`.git`/hidden-dir rules, priority and nesting de-dupe, injected clock.
  - `CleanerTests` (real temp dir, injected permitted root): staging detach + identity mismatch rollback, keep-parent cache clean, symlink component refusal, denylist is/contains refusal, case/NFD path variants refused, `EACCES` chmod retry, `uchg` in Trash, no-Trash volume skip (faked), vanished semantics, launch sweep, freed-bytes accounting.
  - `UndoTests`: restore, collision rename, missing parent, item gone.
  - `ScanCacheTests`: round-trip, mmap read, schema/root/volume mismatch discard, atomic write.
  - `BulkListerSmokeTests` (`TELLTALE_HW_TESTS=1`): real `getattrlistbulk` on temp tree; `PRIVATESIZE` availability; `RECURSIVE_SLIM` availability.
- `MonitorLiveTests`: `StorageModel` consuming mock `ScanEvent`/`CleanEvent` streams; lifetimes (page switch, window close); checked-set running totals; sub-object observation isolation.
- `MonitorUIKitTests`: `TreemapLayout` presorted + O(1) row step equivalence vs current output; `TTSpaceMap` hit-testing; advisory perf tests (10k-child derived state, 10k Cleanup lines).
- `MonitorScreensTests`: snapshots via new `MockStorageState` (`empty`, `scanning`, `map`, `cleanup`, `noFDA`) on `.calm`; ScreenCatalog ids `storage`, `storage-scanning`, `storage-map`, `storage-cleanup`, `storage-nofda`; at 1100 and 1280 widths; confirm flow via `MockDataProvider.storageActions(log:)` + `ActionLog`.
- `MonitorModelTests`: `DashboardPage.storage` title/section; sidebar value format.

## 9. Rollout

1. **Spikes** (answers recorded in the plan): `RESOLVE_BENEATH` on 14; `REMOVEFILE_RECURSIVE_SLIM` on 14; `PRIVATESIZE` via bulk vs per-file; Finder "Put Back" for `trashItem` items; cold-cache scan time (user runs `sudo purge`); `proc_pidinfo` pass cost.
2. Artboards (empty, scanning, map, cleanup, no-FDA; 1100 + 1280).
3. ICR 016 + SPEC/ARCH/DESIGN edits.
4. Signing: `Signing.xcconfig`, `Local.xcconfig.example`, `.gitignore`, `install.sh`.
5. `model:` commit — `DashboardPage.storage` + all switches + new model types.
6. `MonitorDiskTools`: bulk parser + lister + scanner + arena + cache + `telltale-probe --scan`.
7. Classifier + installed-app set + Spotlight query.
8. Cleaner: staging pipeline, guardrails, trash/evict/simctl, undo, in-use pass.
9. Runtime composition + `StorageModel` / `StorageActions` / `StorageActionsLive`.
10. UIKit: `TTSpaceMap`, `TreemapLayout` changes, `TTTable` hover/checkbox, `TTToast`, confirm message.
11. Page UI + snapshots.
12. Sidebar value + popover link.

## 10. Later (out of v1)

- Local Time Machine snapshots · duplicate finder · Mail attachments / iOS backups · low-disk in-app nudge · cleanup history UI · periodic background scan · whole-volume/system areas (need root).
- Incremental rescan: full rescan is ~5 s; FSEvents replay would need arena tombstones. `lastEventId` already cached → a cheap "N changes since scan" staleness badge is the first step.
- Go module cache (`~/go/pkg/mod`): read-only files; either `go clean -modcache` as a tool-command item or the §7.2 chmod-retry path.
- Android SDK / AVDs: user-installed tooling, not junk.

## 11. Risks

- FDA has no public API; probe by reading `~/Library/Safari` and treat `EPERM` as "no FDA".
- `getattrlistbulk` interop is unsafe-pointer heavy; isolate parser in one file with recorded-buffer tests and a smoke test.
- Leftover heuristics can still miss exotic installs; mitigated by Review tier, 90-day age, and Trash mode.
- Unverified until spikes: `RESOLVE_BENEATH` and `RECURSIVE_SLIM` on macOS 14, bulk `PRIVATESIZE`, Put Back for `trashItem`, cold-scan time, process-pass cost.
- Home on a different volume than `dataDirectory` (unusual) loses instant detach; direct `removefile` fallback keeps correctness, only UI latency suffers.
