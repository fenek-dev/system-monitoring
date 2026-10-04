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

## Goldens changed / Requests / Not verified / Blockers
None.
