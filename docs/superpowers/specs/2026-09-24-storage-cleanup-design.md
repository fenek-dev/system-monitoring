# Storage & Cleanup page — design

Date: 2026-09-24 · Status: approved design, pre-plan

## 1. Goal

Add a **Storage** page to the dashboard that shows where disk space goes (analyzer-first) and lets the user reclaim space from curated categories: user caches, leftovers of deleted apps, large & old files, developer junk, Trash.

Non-goals (v1): root/system-area cleanup, background scanning, notifications, duplicate finding, Time Machine snapshots, Mail/iOS backups, cleanup history UI.

## 2. Decisions (from interview)

| Topic | Decision |
|---|---|
| Core job | Analyzer-first (space map), cleanup categories alongside |
| Placement | New sidebar page `Storage`, System section, next to Disk. Disk stays live telemetry |
| Scan scope | Default `~`; any folder or mounted volume via picker |
| Permissions | Detect Full Disk Access (FDA); banner + "Open System Settings" if missing; scan still runs, unreadable dirs shown as restricted |
| Signing | Switch from ad-hoc to Apple Development cert so FDA grant survives rebuilds |
| Delete mode | Regenerable data (caches, build data): permanent remove. User data (leftovers, large files, Archives): Move to Trash with undo |
| Categories | User Caches, Leftovers, Large & Old, Developer, Trash |
| Scan timing | Manual only; last result cached on disk and shown instantly with timestamp |
| Running apps | Their caches shown with `Running` badge, excluded from default selection, listed in confirm |
| Guardrails | Hard denylist + path allowlist enforced in `Cleaner`; confirm dialog for every clean |
| Visualization | Existing `TTTreemap` + `TTTable`, drill-down with breadcrumb |
| Dev junk | Global tool caches + project build dirs in projects untouched > 30 days |
| Large & Old | ≥ 500 MB, or ≥ 50 MB and unused 6 months; thresholds adjustable in page; per-item ignore list |
| Preselection | Only `Safe` tier items preselected; `Review` tier never |
| Integration | Sidebar trailing value; popover Disk section "Free up space…" link |

Implementation defaults chosen without interview:

- Sizes are allocated bytes (`totalFileAllocatedSize` equivalent). Hard links count once. APFS clones may overcount, so reclaimable totals display as `≈`.
- Docker: `Docker.raw` size shown as info only with a `docker system prune` hint; never deleted.
- Scan cache is a file in Application Support, not the GRDB history store.
- After cleaning, the tree updates in place; no automatic rescan.

## 3. Architecture

- **New SPM target `MonitorStorage`**: scanner, classifier, cleaner, scan cache. Not a `Sensor`: scanning is on-demand, so it stays outside `SamplingEngine`.
- **Models in `MonitorModel`**: `StorageNode`, `ScanResult`, `ScanProgress`, `CleanupItem`, `CleanupCategory`, `SafetyTier` (`safe` / `review`), `DeleteMode` (`remove` / `trash` / `simctl` / `none`), `CleanReport`.
- **UI boundary**: UI targets never import `MonitorStorage`. They see
  - `StorageActions` — `Sendable` struct of `@MainActor @Sendable` closures (`scan(root:)`, `cancelScan()`, `clean(items:)`, `undo(report:)`, `ignore(path:)`, `revealInFinder(path:)`, `openFDASettings()`), with `.noop` and mock variants, same pattern as `ProcessActions`.
  - `StorageModel` — `@MainActor @Observable` in `MonitorLive`: scan state, current tree, categories, selection, FDA status, last scan date.
- **Concurrency**: all blocking file I/O runs on a dedicated `DispatchQueue` (concurrent for directory fan-out), never on the cooperative pool. Progress reaches `StorageModel` throttled to ~10 Hz. Scan and clean are cancellable between units of work.
- **Navigation**: new `DashboardPage.storage`. Requires an ICR (ARCHITECTURE §9) and a SPEC ruling adding cleanup to v1 scope. Update exhaustive switches: `Navigation.swift`, `DashboardRoot.swift`, `Sidebar.swift`, `Sampling.swift` (Storage demands volume sampling only).
- **Signing**: `project.yml` gets `configFiles` pointing at committed `Signing.xcconfig`, which does `#include? "Local.xcconfig"`. `Local.xcconfig` (gitignored) sets `DEVELOPMENT_TEAM` + `CODE_SIGN_IDENTITY = Apple Development` + `CODE_SIGN_STYLE = Automatic`. Absent file → current ad-hoc settings, so clean checkouts and CI still build. Commit `Local.xcconfig.example`.

### Scanner engine

`getattrlistbulk`-based walker behind a `DirectoryLister` protocol. One syscall per directory batch returns name, type, allocated size, device, inode, link count, mtime. Directories are fanned out across the storage queue. Fallback lister uses `FileManager.enumerator` + `URLResourceValues` when a volume returns `ENOTSUP`. Tests use an `InMemoryLister`.

## 4. Page layout

Grid per DESIGN §3.0 (padding 20, gap 12, `grid3`).

- **Header trailing**: scan root chip (`~ ▾`: Home / Choose Folder… / mounted volumes) · `Scanned 2 h ago` · `Scan` / `Rescan` (becomes `Cancel` while scanning).
- **FDA banner** (only without FDA): "Some folders unreadable. Grant Full Disk Access for complete results." + `Open System Settings`. Dismissible per session.
- **Stat strip**: Capacity · Used · Free (`ShellFormat.freeSpace`, same field as sidebar) · Purgeable · Reclaimable ≈ (last scan) · Trash. Tiles always present (stable positions). Trash shows `Empty` at 0 B, `—` when unreadable (no FDA); Reclaimable shows `—` before first scan.
- **Mode switch** (`TTSegmented`): `Space Map` (default) | `Cleanup`.

### Space Map

- Breadcrumb `~ › Library › Caches`.
- Treemap card (2 cols) + children table card (1 col: Name, Size, %, Items). Hover synced between them. Click folder to drill in.
- Children under 0.5% of parent merge into one "N smaller items" tile.
- Restricted dirs: hatched tile, size `—`, tooltip "Needs Full Disk Access".
- Row/tile menu: Reveal in Finder · Move to Trash… · Ignore. Trash disabled with reason tooltip on denylisted paths.

### Cleanup

- Left card: category list (User Caches · Leftovers · Large & Old · Developer · Trash), each with total size, selected size, tier mix.
- Right card: `TTTable` of the category's items — checkbox · icon + name · size · tier badge · `Running` badge · last used. Items grouped per owning app as children rows. Large & Old card header has threshold `TTSegmented`.
- Sticky footer: `Selected 14.2 GB · 37 items` + `Clean…` primary button.

### States

| State | UI |
|---|---|
| Never scanned | `TTEmptyState` + Scan button |
| Scanning | Progress card: files counted, bytes seen, current path (middle-truncated), Cancel. Stat strip stays live |
| Cached result | Rendered immediately with timestamp |
| Root error | Empty state with reason |

### Outside the page

- Sidebar trailing value: `12 GB reclaimable` after a scan, else free space.
- Popover Disk section: `Free up space…` link opens the Storage page.

Design canvas is binding and no artboard exists: artboards for empty, scanning, space map, cleanup, and no-FDA states come first.

## 5. Scan rules

- Never cross mount points (device ID check). Never follow symlinks.
- Hard links (`nlink > 1`) deduplicated by `(dev, inode)`.
- iCloud / File Provider dataless files: allocated bytes only, never materialized, tagged `cloud`.
- Packages (`.app`, `.photoslibrary`, `.xcarchive`, other bundle dirs) are leaf nodes: size included, no drill-down.
- Storage: flat arena of nodes (parent index). Nodes kept for directories and files ≥ 1 MB; smaller files folded into their directory's `smallBytes` / `smallCount`.
- Unreadable directory → `restricted` node with `size = nil`.
- Cache: arena serialized to `~/Library/Application Support/Telltale/storage-scan.bin` with root path, scan date, schema version. Any mismatch → discard.

## 6. Classification

Each path belongs to at most one category. Priority: Developer > User Caches > Leftovers > Large & Old.

| Category / item | Source | Tier | Delete mode |
|---|---|---|---|
| User Caches | children of `~/Library/Caches` and `~/Library/Logs`; owner resolved bundle ID → installed app | Safe; `com.apple.*` → Review | remove |
| Leftovers | reverse-DNS dirs/plists in `~/Library/{Application Support, Caches, Containers, Group Containers, Preferences, Saved Application State, HTTPStorages, WebKit}` with no installed app (LaunchServices + `/Applications` + `~/Applications`); `com.apple.*` never included | Review | trash |
| Large & Old | files ≥ 500 MB, or ≥ 50 MB and unused ≥ 6 months. "Unused" = Spotlight `kMDItemLastUsedDate` (queried for candidates only), fallback mtime | Review | trash |
| Dev: DerivedData, package caches (Homebrew, npm, yarn, pnpm, pip, cargo, gradle, CocoaPods), JetBrains caches (`~/Library/Caches/JetBrains`) | fixed paths | Safe | remove |
| Dev: iOS DeviceSupport (all but newest per platform) | fixed path | Review | remove |
| Dev: unavailable simulators | `xcrun simctl delete unavailable`, size from their device dirs | Review | simctl |
| Dev: Xcode Archives older than 180 days | fixed path | Review | trash (not regenerable) |
| Dev: project build dirs | `node_modules`, `.build`, `target`, `Pods`, `build` with matching sibling marker (`package.json`, `Package.swift`, `Cargo.toml`, `Podfile`, gradle/CMake file); project newest mtime > 30 days | Review | remove |
| Dev: Docker | `Docker.raw` size + `docker system prune` hint | — | none |
| Trash | `~/.Trash` | Review | remove (empty) |

- Running apps: `NSWorkspace.runningApplications` bundle IDs matched to item owner at list build and again at Clean.
- Ignored paths hidden from Cleanup; still visible in Space Map.
- macOS 14 "access data from other apps" prompt may fire for `Containers`; FDA covers it.

## 7. Cleanup flow

1. `Clean…` pressed.
2. Running-app recheck; items whose owner started since list build get unticked with a notice.
3. Confirm through `ConfirmDialogHost` (`await confirm(...)`): title `Clean 14.2 GB?`; message splits "Delete permanently: X (caches, build data)" and "Move to Trash: Y (leftovers, large files)"; lists running apps if ticked; `Clean` (destructive) / `Cancel`.
4. Execute item by item on the storage queue; footer shows `Cleaning 12/37…`. Cancel takes effect between items.
5. Result `TTToast`: `Freed 13.9 GB · 2 items skipped` + `Show` (skip reasons). If anything was trashed: `Undo` restores via recorded trash URLs while the toast lives.
6. Tree and categories update in place; page requests an immediate volume sample to refresh Free.

### Cleaner primitives

- `remove`: `FileManager.removeItem`. For cache directories, delete contents and keep the directory.
- `trash`: `FileManager.trashItem(at:resultingItemURL:)`; resulting URL kept for undo.
- `simctl`: `xcrun simctl delete unavailable` via `Process`, 60 s timeout; skipped if `xcrun` absent.
- Per-item errors collected into `CleanReport`, never thrown: permission denied, busy, changed since scan. Vanished = success. Partial directory removal reports bytes actually freed.

### Guardrails (enforced in `Cleaner`, not only UI)

- **Denylist** (never deletable): `/`, `~`, `~/Library`, any direct child of `~/Library`, `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/private`, `~/Library/Keychains`, `~/Library/Mobile Documents` root, contents of `*.photoslibrary`, the scan root itself.
- **Allowlist**: target must resolve (`realpath`) inside `~` or the user-chosen scan root; no symlink component may escape it.
- **Freshness**: re-`lstat` before acting; inode or type change since scan → skip "changed since scan".
- No root, no `sudo`, no privileged helper. `EPERM` → skip with reason.

### Ignore list and logging

- `UserDefaults` key `storage.ignoredPaths` via the injected defaults (works with `InMemoryDefaults`). `Show ignored` toggle in Cleanup to manage.
- `os_log` subsystem category `storage`: one line per deleted path with bytes and mode.

## 8. Testing

- New `MonitorStorageTests`:
  - `ScannerTests` — `InMemoryLister`: sizes, hard-link dedupe, small-file folding, restricted nodes, package leafs, mount-boundary stop, cancel.
  - `ClassifierTests` — fixture trees: category priority, bundle-ID matching vs fake installed-app set, build-dir markers, age thresholds with injected clock, `com.apple.*` rules, ignore list.
  - `CleanerTests` — real temp dir: remove-contents-keep-dir, trash + undo, denylist refusal, symlink-escape refusal, changed-since-scan skip, vanished = success, partial-failure aggregation.
  - `ScanCacheTests` — round-trip, schema/root mismatch discard.
  - `BulkListerSmoke` — real `getattrlistbulk` on temp tree, gated by `TELLTALE_HW_TESTS=1`.
- `MonitorScreensTests`: snapshots for `MockScenario` `storage-empty`, `storage-scanning`, `storage-map`, `storage-cleanup`, `storage-nofda`; confirm flow via mock `StorageActions` + `ActionLog`.
- `MonitorModelTests`: `DashboardPage.storage` title/section; sidebar trailing value format.
- Safety net: `Cleaner` takes an injected permitted root; tests pass a temp root so no fixture can reach the real home.
- Perf (advisory): ~1M-file home scanned in < 60 s on Apple Silicon. Report, don't tune.

## 9. Rollout order

1. Artboards (empty, scanning, space map, cleanup, no-FDA)
2. ICR for `DashboardPage.storage` + SPEC ruling adding cleanup to scope
3. Signing change: `Signing.xcconfig` + `Local.xcconfig.example`, add `Local.xcconfig` to `.gitignore`
4. `MonitorStorage`: lister + scanner + scan cache
5. Classifier
6. Cleaner + guardrails
7. `StorageModel` / `StorageActions` wiring (`LiveSensorFactory`-adjacent composition in App)
8. Page UI + snapshots
9. Sidebar value + popover link

## 10. Later (out of v1)

Local Time Machine snapshots · duplicate finder · Mail attachments / iOS backups · low-disk in-app nudge · cleanup history · periodic background scan · whole-volume/system areas (need root).

Developer targets deliberately excluded:
- Go module cache (`~/go/pkg/mod`): files are read-only, so `removeItem` fails; correct path is `go clean -modcache`. Revisit as a tool-command item like `simctl`.
- Android SDK / AVDs: large but user-installed tooling, not junk.

## 11. Risks

- FDA detection has no public API; probe by reading a known protected path (e.g. `~/Library/Safari`) and treat `EPERM` as "no FDA".
- `kMDItemLastUsedDate` missing for files Spotlight never indexed (excluded volumes, dev dirs) → mtime fallback may over-report "old".
- Leftover detection false positives for apps installed outside `/Applications` and not registered with LaunchServices → Review tier + Trash mode keeps them recoverable.
- `getattrlistbulk` Swift interop is unsafe-pointer heavy; isolate in one file with smoke test.
