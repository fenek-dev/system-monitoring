# W4-final brief — Storage goldens, renders, real-app screenshots, live interaction + real-data checks

Self-contained. Owner: the W4a agent (or a fresh agent with this brief). Source of truth: **merged code > this brief > plan** (`docs/superpowers/plans/2026-10-04-storage-cleanup.md` §0, §4 W4-final, §6 S4; spec `docs/superpowers/specs/2026-09-24-storage-cleanup-design.md` §4, §7.1; `docs/design/DESIGN.md` §3.0, §3.1 `:633`, §3.12 `:1006`, **§3.17** `:1174-1192`, §2.28 `:539`, §2.29 `:541-547`, §5.8). No artboards (user decision): renders and screenshots are the check — **Read every PNG**. Paths under `MonitorCore/` unless they start with `App/`, `docs/`, `scripts/`. Lines verified at `feat/storage` `d32c471`; re-verify after W4a/W4b/W4c merged.

## Goal

1. 10 storage goldens via `assertScreen`.
2. Renders of every storage id + affected siblings, compared with DESIGN §3.17; fix and re-render.
3. Running-app screenshots (mock and real) of every affected screen at **1100×720 and 1280×860**, incl. siblings of shared components.
4. Live interaction checks, scanner access policy (no-FDA) check, one controlled real deletion.

## Worktree

- `/Users/arturvorokov/Documents/Projects/telltale-storage-w4final`, branch `ws/storage-w4final`, from `feat/storage` **after W4a, W4b, W4c are merged**. Commit only there; rebase before handing back. **Don't merge.**
- Start: `git status`; `.codegraph/` missing → `codegraph init` (exclude via `$(git rev-parse --git-common-dir)/info/exclude`), else `codegraph sync -q`. `codegraph explore` before grep.

## Ownership

Own: `Tests/MonitorScreensTests/StorageSnapshotTests.swift` (new), `__Snapshots__/storage-*.png`, `docs/superpowers/plans/progress/W4-final.md`, screenshots under `docs/superpowers/plans/progress/W4-final/` (PNG, ≤ 2 MB each; commit them — orchestrator asked for screenshots in progress), `docs/design/DESIGN.md` + `docs/RULINGS.md` (**only** the Finder Put Back result line, T7). Fixes found in T2–T6: all W4 files (`Pages/Storage/**`, `Shell/{ScreenCatalog,LaunchOptions,Sidebar}.swift`, `Popover/{FlyoutView,FlyoutModel,PopoverModel}.swift`, their tests/goldens) — one commit per fix, named in the progress file. Conditional: `Sources/MonitorMocks/MockStorageState.swift` only to align the `noFDA` fixture with the access policy below (keep `StorageMockTests` green).

Forbidden: `Sources/MonitorLive/**`, `MonitorModel/**`, `MonitorDiskTools/**`, `MonitorRuntime/**` except via Requests; any user data outside the fixtures named in T6.

## Inputs

- Catalog ids (W4c, `Shell/ScreenCatalog.swift`): `storage` (auto from `DashboardPage.allCases`, default state = empty), `storage-1100`, `storage-scanning`, `storage-scanning-1100`, `storage-map`, `storage-map-1100`, `storage-cleanup`, `storage-cleanup-1100`, `storage-nofda`, `storage-nofda-1100`; sizes 1280×860 (`ScreenCatalog.dashboardSize` `:32`) / 1100×720 (`ShellStyle.dashboardMinSize` `Shell/ShellStyle.swift:45`).
- `assertScreen(_:scenario:)` `Tests/MonitorScreensTests/Support/ScreenTestSupport.swift:62` → golden `<id>-<scenario>`; record `TELLTALE_RECORD=1 scripts/test.sh StorageSnapshotTests` (`Sources/MonitorSnapshotTesting/AssertSnapshot.swift:20`); `scripts/ci.sh` is strict.
- Renders: `scripts/render.sh <id> calm` → `MonitorCore/.build/renders/<id>-calm.png` (`scripts/render.sh:5`).
- App: `scripts/build.sh`; `scripts/run.sh [--mock <scenario>] [--mock-storage <kind>] --open-dashboard storage` (Debug build, data dir `~/Library/Caches/dev.telltale-dev/<worktree>`, `scripts/run.sh:16`; `--mock-storage` from W4c, ⚠ verify name); `scripts/install.sh` → `/Applications/Warden.app` (user granted FDA to that app; signing `scripts/install.sh:42-45`).
- Mock fixture facts (`docs/superpowers/plans/progress/W3c.md`): items 1–21; in use 4 (Chrome); running 1 (Spotify); ignored 6 (Figma); evict 12; Docker `.none` 19; `noFDA` restricted: Containers, Group Containers, Safari, AddressBook (+ Mail/Messages in all states).
- **Scanner access policy (decision, binding):** without FDA the GUI app lets macOS show its one-time prompts for Desktop / Documents / Downloads / iCloud Drive / user-chosen volumes (allow them); other apps' containers (`~/Library/Containers`, `Group Containers` — `Sources/MonitorDiskTools/Scan/ScanRun.swift:323-325`, policy `Scan/ScanRoots.swift:43-56`) and Contacts / Calendars / Reminders / Photos / Mail / Messages / Safari data are **restricted** tiles/rows ("Needs Full Disk Access", size "—"; `EACCES` → restricted, `Scan/DirectoryLister.swift:57`). FDA probe: `~/Library/Safari` (`Scan/ScanRoots.swift:21-37`; missing folder = inconclusive = treated as not granted by the scan policy `:54-55`).

## Tasks (prefix `test(storage-ui):` for goldens/screens, `fix(storage-ui):` for fixes)

- [ ] **T0** Verify inputs (ids, option names, policy lines) on merged code; note deltas. Accept: progress "Inputs verified".
- [ ] **T1 `StorageSnapshotTests`** (`@Suite @MainActor`, one parametrized test over the 10 ids, scenario `.calm`) → goldens `storage-calm`, `storage-1100-calm`, `storage-scanning-calm`, `storage-scanning-1100-calm`, `storage-map-calm`, `storage-map-1100-calm`, `storage-cleanup-calm`, `storage-cleanup-1100-calm`, `storage-nofda-calm`, `storage-nofda-1100-calm`. Record, Read all 10. Then run twice without record → green both times (determinism). Accept: exactly these 10 new PNGs.
- [ ] **T2 Render review vs DESIGN §3.17** — every storage id plus siblings `disk calm`, `processes calm`, `thermals calm`, `popover calm` (shared TTTable/TTToast/TTSpaceMap/sidebar/flyout). Per id note: grid/padding, header trailing order (root chip · Scanned … · Scan/Rescan/Cancel · Pause · Settings), strip (Purgeable gone at 1100), mode switch, Space Map (breadcrumb, tiles vs table same set, "N smaller items", hatch), Cleanup (columns, badges, footer 44), states copy. **Scanning ids: confirm no "Scanned …" and no clock/date text** (Read the PNG; `grep -n "Date()" MonitorCore/Sources/MonitorScreens/Pages/Storage/*.swift` must show only the `\.now ?? Date()` fallback). Fix → re-render → re-record goldens touched. Accept: table in progress file, every id "OK" or fixed with commit hash.
- [ ] **T3 Mock app screenshots** (`scripts/build.sh`; `scripts/run.sh --mock calm --mock-storage <kind> --open-dashboard storage` for kinds `empty, scanning, map, cleanup, noFDA`) at 1280×860 and 1100×720 each; also Disk page, Processes page, popover + Disk flyout (link "Free up ≈X…" after the mock summary loads). Capture: window id from a throwaway Swift script outside the repo (`/tmp/winid.swift`, `CGWindowListCopyWindowInfo`, owner `Warden`, this build's pid) → `screencapture -o -l <id> <file>`; resize via `osascript -e 'tell application "System Events" to tell process "Warden" to set size of window 1 to {1100, 720}'`. Accessibility/Screen Recording denied → stop that part, list exactly what the user must grant, mark "not verified". Accept: files under `progress/W4-final/`, each Read and compared with its render (differences = bug or explained, e.g. real icons vs letter tiles).
- [ ] **T4 Live interaction checks** (mock `cleanup`/`map`; drive with a throwaway CGEvent script `/tmp/ui-drive.swift` — mouse move/click/double-click/right-click/key events; same permission rule). Record each as pass/fail/not verified with a screenshot when visual:
  - Cleanup: click on row **text** selects the row; double-click on a group row expands it (item row → Reveal, logged in mock as `revealInFinder`); click on a **checkbox** toggles it and does **not** select/activate the row; Space toggles the selected row's checkbox; disabled Docker checkbox shows its tooltip.
  - Space Map: hover a tile → matching table row highlights and vice versa; tile tooltip `{name} · {size} · {share}%`; restricted tooltip "Needs Full Disk Access"; click tile drills; table double-click drills; arrows move hover, Return drills, ⌘[ and Backspace go up; right-click tile/row → Reveal · Move to Trash… · Ignore, Trash disabled with reason on `~/Library`.
  - FDA banner (`noFDA`): visible, dismiss hides it for the session; `Open System Settings` in a **Debug live** run (`scripts/run.sh --open-dashboard storage`, no `--mock`) opens Privacy & Security › Full Disk Access (mock's `openFDASettings` is a no-op).
  - Confirm: Clean… with id 4 checked → in-use notice; dialog title `Clean ≈…?`, lines delete/trash/remove-download as applicable, in-use list; Cancel → nothing happens.
  - Toast: Clean → "Freed X · Moved Y to Trash" + Show (if skips) / Empty Trash (asks first) / Undo; Undo restores rows; lifetime ~10 s with Undo.
- [ ] **T5 No-FDA real scan (Debug build, real mode)**: `scripts/run.sh --open-dashboard storage`, Scan `~`. Allow the one-time prompts for Desktop/Documents/Downloads/iCloud Drive (click Allow or ask the user; record which appeared). Screenshot at both sizes: FDA banner; Space Map root; `~/Library` showing `Containers`, `Group Containers`, `Mail`, `Messages`, `Safari`, `Calendars`, `Application Support/AddressBook` (Contacts), `Reminders` data and `Pictures/Photos Library.photoslibrary` as hatched restricted tiles with "—" (whichever exist on this Mac); Cleanup with restricted-derived totals. Compare with `storage-nofda` render; if the mock fixture's restricted set contradicts the policy (e.g. Mail/Messages restricted even with FDA, Calendars/Reminders/Photos missing), align `MockStorageState` (conditional ownership) and re-record the nofda/map/cleanup goldens, or record why not.
- [ ] **T6 Real-data check with FDA (installed app — careful)**: `scripts/install.sh`; launch `/Applications/Warden.app`; confirm the FDA banner is **absent** (FDA lost after reinstall → stop, ask the user to re-grant; don't proceed). Scan `~`; screenshot Space Map, Cleanup, confirm dialog, toast at both sizes.
  - Fixture (the **only** thing ever cleaned): `mkdir -p ~/Library/Caches/com.example.storage-fixture && dd if=/dev/urandom of=~/Library/Caches/com.example.storage-fixture/blob.bin bs=1m count=8` **before** the scan. In Cleanup › User Caches verify the fixture row is listed and checkable **before** anything else (screenshot).
  - Untick everything else (category by category; group toggles; Space). Proceed only when the footer reads exactly `Selected {fixture size} · 1 item` and every other category's selected total is 0. If that needs more than ~40 manual toggles, or anything is ambiguous → stop and ask the user.
  - Clean… → the dialog title must equal the fixture size and its only line must be "Delete permanently: …"; otherwise **Cancel**. Confirm → fixture dir emptied/removed (keep-parent caches keep the dir), toast "Freed …"; verify with `ls -la ~/Library/Caches/com.example.storage-fixture`.
  - Undo check: `dd … of=~/warden-fixture-undo.bin bs=1m count=2`, rescan, Space Map › right-click it › Move to Trash… → confirm → toast Undo → file back at `~/warden-fixture-undo.bin` (verify with `ls`), then `rm` it yourself.
  - Put Back check (spikes §4): same with `~/warden-fixture-putback.bin`, moved to Trash via the app, no Undo. Finder › Trash › right-click → "Put Back" is a **user check**: ask the user (or drive Finder via the CGEvent script if permitted) and record the result; then remove the fixture from the Trash (`ls ~/.Trash | grep warden-fixture` → `rm` that path only).
  - Nothing else is cleaned, trashed, ignored or emptied. Never press Empty Trash in the installed app.
- [ ] **T7 Put Back result** → one line in `docs/design/DESIGN.md` §3.17 Toast bullet (`:1187`, currently "No Finder 'Put Back' claim … until verified") and a ruling in `docs/RULINGS.md` (follow its existing format). Unverified → leave both unchanged, say so.

## Tests

- `StorageSnapshotTests`: **10 snapshot tests** (1 parametrized function × 10 ids) → bug: Storage page layout/state regressions (wrong state per fixture, clipped header at 1100, wall-clock text in scanning).
- No other new tests; fixes add a test only when they fix a logic bug (name it).

## Gates

- Iterate: `scripts/test.sh StorageSnapshotTests`.
- Final: `scripts/ci.sh StorageSnapshotTests StorageCleanupTests StoragePageLogicTests StorageFormatTests ShellSidebarValueTests ShellScreenCatalogTests ShellSnapshotTests PopoverTests FlyoutTests DiskSnapshotTests ProcessesSnapshotTests ComponentSnapshotTests StorageMockTests` → `ci.sh: OK`; quote it. (Plan listed `ShellCompositionTests`: that is a file; `scripts/test.sh` filters by type name and fails on zero tests, `scripts/test.sh:35-37`.)

## Rules

- Edit/Write tools only for repo file edits (no sed/heredoc/python); throwaway driver scripts live in `/tmp`, never in the repo.
- No `@unchecked` outside `MonitorMocks` (`scripts/ci.sh:63-69`), no `as any`/lint disables/swallowed errors. Never weaken a test or re-record a golden you haven't Read.
- Real data: only the three fixtures above; anything unexpected in a dialog → Cancel and report.
- Comments explain why. No debug prints, TODO stubs, commented-out code.
- Tool output ≤ 100 lines (`tail`/`grep`).
- 2 failed attempts with the same approach → stop, re-diagnose, note it.
- Commits: prefixes above; message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- Progress file `docs/superpowers/plans/progress/W4-final.md`: Plan / Done (hashes) / Renders (id → verdict) / Screenshots (file → what) / Live checks (pass/fail/not verified) / Access policy observations / Real-data log (exact commands + results) / Put Back / Requests / Not verified / Blockers.
- Don't merge; no Codex reviews. Final report ≤ 15 lines: branch, last commit, ci.sh line, goldens, failed/unverified checks, real-data result.
