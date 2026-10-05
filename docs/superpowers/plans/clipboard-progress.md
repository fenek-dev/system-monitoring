# Clipboard history — progress

Plan: `2026-10-06-clipboard-history.md`. Spec: `../specs/2026-10-06-clipboard-history-design.md`.
Branch `dev`, one checkout, nothing committed (user has not asked for commits).

| Task | State | Notes |
|---|---|---|
| A core + store | done | 22 tests pass; mutation-checked |
| B picker UI + settings | done | suites pass strict; renders reviewed. Open: Settings note says "⌘⇧V", recorder shows "⇧⌘V" (fix after C) |
| C app wiring | code written, app builds | User said "stop testing" (fullscreen game in front): no tests, app runs, pasteboard writes or screenshots until they say go |

Resumed (user: "go"). Done since:
- Settings goldens re-recorded (3); strict: ShellSnapshotTests 7, ShellSettingsSensorsTests 3, ClipboardSettingsTests 3,
  ClipboardPickerTests 15, ClipboardSnapshotTests 1, ClipboardCoreTests 9, ClipboardStoreTests 13, HotKeyRecorderTests 12.
- App build OK. Mock run on normal desktop: picker stays open at cursor, caret in search field, corners clean
  (the earlier 1 s close was the fullscreen game taking key).
- Live run: copy → row; re-copy → moved to top, no duplicate; concealed copy → not stored.
- Codex review r1 running (delegate_task clientRequestId clipboard-history-review-r1).
- Codex r1: 9 fixed, tests-for-App-glue rejected. r2: 1 P1 (⌘V after reopen during 60 ms pause) + 1 P2 (stale
  payload failure closing a reopened picker) fixed; other fixes confirmed. Review closed (2 rounds max).
- Scroll indicators hidden. After all fixes: `ci.sh: OK` (r1 fixes), `BUILD SUCCEEDED` (r2 fixes).
Still open:
- Paste flow (Return / ⌘n → pasteboard + marker + ⌘V) not exercised: synthetic hotkey does not trigger the Carbon
  hotkey, Debug build not Accessibility-trusted. Needs the user by hand.
- Legacy scroll bar track narrows rows when "always show scroll bars" is on; consider hiding indicators.

Original list (before resume):
- Settings note now uses `spec.display` ("⇧⌘V"): `shell-settings*` goldens need re-record (3 files) — not run.
- Picker closed ~1 s after `--open-clipboard` in the one mock run; cause unknown (a fullscreen game was frontmost,
  likely took key back). Re-check on a normal desktop: stays open, search field focused, corners/shadow.
- Live checks never run: capture row in sqlite, re-copy dedup, concealed skip, own-marker types after
  `PasteService.write`, paste into TextEdit / Terminal / browser (Debug build is not Accessibility-trusted).
- Codex review of whole diff (gpt-6-astra, xhigh).
| Verify (run app, screenshots) | — | |
| Codex review | — | |
