# W4-final progress (worktree telltale-storage-w4f, branch ws/storage-w4f)

Scope reduced by orchestrator: no install.sh, no fixture/real deletion, no further GUI driving. Orchestrator runs the live checks (list below).

## Done
- `005c407` fix: TTSpaceMap per-tile `share` override (tooltip/accessibility %), SpaceMapView passes known-bytes share; test `tileShareUsesKnownBytesOnly` (StoragePageLogicTests).
- Goldens + `StorageSnapshotTests` (10 ids, calm) + fix "empty Cleanup table cells keep their column width" (CleanupRows: `Color.clear` for empty Tier/In use cells; a bare EmptyView dropped its frame, so Last used dates shifted left on rows without an In use badge). Determinism: 2 consecutive non-record runs green.
- fix TTTable row selection (see Findings 1).

## Renders vs DESIGN §3.17 (all 10 goldens Read)
| id | verdict |
|---|---|
| storage / -1100 | OK: header `~` chip · Scan · Pause · Settings, strip with Purgeable (gone at 1100), Space Map/Cleanup switch, empty copy + Scan |
| storage-scanning / -1100 | OK: no "Scanned …", no clock/date; Cancel in header and panel; ≈ sizes; tail "3 smaller items"; Items column dropped at 1100. `grep Date()` in Pages/Storage: only `now ?? Date()` fallbacks |
| storage-map / -1100 | OK: breadcrumb `~`, tiles and table same set, Purgeable gone at 1100 |
| storage-cleanup / -1100 | fixed (Last used alignment), then OK; Last used column dropped at 1100; footer 44 with Clean… |
| storage-nofda / -1100 | OK: FDA banner (Open System Settings, Dismiss), hatched Desktop tile with "—", table row "—" |
Siblings (disk, processes, thermals, popover): not re-rendered; their goldens are in the gate and stay green (TTTable change is gesture-only).

## Mock app screenshots (this stream, before the scope change)
Files in `progress/W4-final/`, window frontmost, 1280x860 and 1100x720, all Read; each matches the render of the same id.
mock-empty-{1280,1100}, mock-scanning-*, mock-map-*, mock-cleanup-*, mock-noFDA-*.
Differences vs renders (expected): real app icons (Chrome) vs letter tiles; real clock ("Scanned Sep 24"); Reclaimable 73.8 GB live vs 68.1 GB render (live classification date); traffic lights.

## Findings
1. BUG fixed (UIKit, shared): `TTTable` row tap gestures lived in a `.background` layer, so clicks on cell text never selected a row (verified live: Cleanup, Space Map, Overview tables; Processes uses its own table and worked). Now plain `onTapGesture(count: 2)` + `onTapGesture` on the row (child checkbox keeps priority). Verified live after fix: click on row text selects; click on a checkbox toggles it and leaves the selection unchanged.
2. NOT fixed, to verify: Space did not toggle the selected row's checkbox. Keyboard focus sat on the first (disabled) checkbox (focus ring visible), not on the table, so `.onKeyPress(.space)` on the table never fired. Likely fix: `@FocusState` on `TTTable`'s `.focusable()` and set it in the row tap.
3. NOT confirmed: double-click on the Slack group row did not expand it in one attempt (synthetic CGEvent clickState 2; may be the driver or the stacked tap gestures). Re-check by hand.
4. Inactive window shows "—" in sidebar/strip (sampling stops while the app is not frontmost) - looks by design, not Storage-specific.
5. Pre-existing, outside Storage: Overview at 1100x720 clips the Power/Disk cards on the right.
6. Mock `noFDA` restricts only Desktop; brief's policy list (Containers, Mail, Safari…) not reflected in the fixture; unchanged (not needed for goldens).

## Live-check checklist for the orchestrator
Launch (Debug mock): `scripts/run.sh --mock calm --mock-storage <kind> --open-dashboard storage` (kinds: empty, scanning, map, cleanup, noFDA). App must be frontmost, else sampling stops and the strip shows "—".
1. cleanup: click row text of "Homebrew" or "Slack" (non-zebra row: Slack), move mouse away. Expect: blue selected fill stays.
2. cleanup: click Homebrew checkbox. Expect: toggles, selection unchanged, footer count/bytes update.
3. cleanup: select Slack, press Space. Expect: Slack checkbox toggles (Finding 2: currently fails).
4. cleanup: double-click Slack (group). Expect: expands to 2 child rows. Double-click an item row. Expect: reveal in Finder (mock logs `revealInFinder`).
5. cleanup: hover Spotify/Chrome (In use) checkboxes. Expect: tooltip on disabled ones per brief; Clean… with Chrome checked shows in-use notice.
6. cleanup: Clean… dialog. Expect: title `Clean ≈…?`, delete/trash/remove-download lines, in-use list; Cancel does nothing; Confirm shows toast "Freed X · Moved Y to Trash" with Show/Empty Trash/Undo; Show pins the toast; Undo restores rows; toast ~10 s with Undo; during cleaning all checkboxes disabled.
7. map: hover tile, matching Contents row highlights, and vice versa. Tooltip `{name} · {size} · {share}%` (shares sum over known bytes, e.g. Library 44%). Restricted tile (noFDA, Desktop) tooltip "Needs Full Disk Access".
8. map: click tile drills; table double-click drills; arrows move hover, Return drills, ⌘[ and Backspace go up; right-click tile/row: Reveal · Move to Trash… · Ignore (Trash disabled with reason on ~/Library).
9. noFDA: banner visible; Dismiss hides it for the session; Open System Settings opens Full Disk Access only in a live run (`scripts/run.sh --open-dashboard storage`, no --mock).
10. Real-data checks (T5/T6/T7 of the brief) not done by this stream.

## Not verified
Live checks 3-10 above, Put Back, real-data scan, installed-app run.
