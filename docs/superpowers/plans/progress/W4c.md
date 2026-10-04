# W4c progress

## Plan / Done
- P0 (T0-T2): StorageFormat, CleanupView/CleanToastHost stubs, storage catalog entries. Done.
- Next: T3 sidebar, T4 flyout link, T5 --mock-storage, T6 launch summary.

## P0 ready
See `git log` on ws/storage-w4c (commit "feat(storage-ui): P0 scaffold").

## Interface deltas
- `StorageModel.seedAccess(hasFullDiskAccess: Bool?, availableRoots: [ScanRoot])` (StorageModel.swift:98) used by catalog.
- `ScreenCatalog.storageModel(_ kind:) -> StorageModel`; `context(for:page:ticks:storage:)`; `dashboard(_:scenario:size:storage:)`.
- Entries: storage (empty model), storage-1100, storage-{scanning,map,cleanup,nofda}[-1100].
- `StorageMode`, `\.storageInitialMode` (cleanup entries set `.cleanup`), `StorageFormat.{bytes,estimateTooltip,scannedAgo,selection}`.

## Notes
- Headline style gives "12.0 GB" (brief said "12 GB"); tests use the real output.

## T3-T6 done
- Sidebar Storage value, Disk-flyout link (FlyoutStorageLink, PopoverActions.openStorage), --mock-storage / TELLTALE_MOCK_STORAGE, launch-time windowDidOpen in AppEnvironment (W3b loaded the summary only in DashboardWindowController.show).
- New golden: flyout-disk-calm. No other goldens changed.
- Break-check: dropped the ≈ branch -> StorageFormatTests red (2 failures), reverted.

## Requests
- Sidebar "≈68 GB reclaimable" truncates to "≈68 GB recl…" in the 220-pt sidebar (TTSidebarItem is MonitorUIKit, not mine). Needs minimumScaleFactor / shorter copy; orchestrator decision.

## Not verified
- Flyout link click in the running app; only the mock launch line checked.

## Blockers
None.
