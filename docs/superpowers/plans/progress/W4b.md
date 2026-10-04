# W4b progress (Cleanup mode, clean flow, toast)

## Plan / Done
T0-T4 done (one commit). T5 live app checks: see Not verified.

## Interface deltas
- `isCheckable`/`displayBytes` already public (CleanupLines.swift:64-66).
- Table gets `cleanup.lines()` flat (children already included) instead of TTTable `children:`; disclosure chevron is a local button writing `cleanup.expanded` (TTTable's internal expanded state would diverge from the model's).
- Files: `CleanupView` (cards, footer, `CleanupCategory.cleanupTitle` private), `CleanupRows` (`CleanupRow`, table), `CleanConfirm` (`ConfirmAsk`, `CleanConfirmText.make`, `CleanFlow.run/ask`), `CleanToast` (`CleanToastText`, `CleanToastActions.emptyTrash`, `CleanToastHost`, `CleanToastView`).
- `CleanupView` uses `GridRow(columns: 3, spans: [1, 2])` and a `GeometryReader` to size the grid to (height - 44 footer - gap): W4a must give it a bounded height (not inside an unbounded ScrollView) and page padding around it.
- Toast host ignores reports of Undo / Empty Trash runs it started itself (`ownRun`); a clean started elsewhere (Space Map trash) toasts. Empty Trash gives no toast.
- Large & Old threshold control sits on its own row under the card title (does not fit beside it at 840 pt).

## Live checks (observed)
Renders via a throwaway test (deleted) at content widths 840 (compact) and 1020: categories with badges, groups collapsed/expanded, In use badges (ids 1/4), disabled Docker checkbox, ignored hidden / shown, iCloud "Remove Download", threshold row, footer "Selected ≈26.1 GB · 9 items", confirm dialog with 5 in-use names + "+2 more", toast with Show/Empty Trash/Undo. Fixed from renders: Developer "selected" text wrapped, In use column overflow, Show ignored wrapping at 840.

## Goldens changed
None.

## Requests
None.

## Not verified
- Real-app interaction (T5): click/checkbox/Space/double-click, dialog, toast timing, Empty Trash prompt. W4a page not merged, so no dashboard to drive.
- Skipped-items sheet (sheets do not render in snapshots), footer Cleaning/Cancel/Freeing states, Unignore link rendering.
- Stale `ownRun` if an Undo/Empty Trash stream never emits `.finished`: would swallow the next toast.

## Blockers
None.
