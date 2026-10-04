# ICR 018 (W1): Storage page and storage model types

Number 018: ICR 16 is the overlay (ARCH §11), 017 is claimed by the network spec. The storage spec (`docs/superpowers/specs/2026-09-24-storage-cleanup-design.md`) says "ICR 016"; this record replaces that.

## What

Additive changes to `MonitorModel`, all `public`, `Sendable`, explicit inits:

- `DashboardPage.storage` (after `.disk`, title "Storage", section `.system`). `UIVisibility.demand` for `.storage` is `.none` (the Storage page reads no sensor beyond `VolumeSensor`, which has no `requires`).
- New folder `Sources/MonitorModel/Storage/` with the types listed in plan `docs/superpowers/plans/2026-10-04-storage-cleanup.md` §3.1–3.2:
  - Tree: `StorageNodeID`, `StorageNodeFlags`, `StorageMarker`, `FileIdentity`, `StorageTree` (immutable struct-of-arrays snapshot, `childOrder` + `childPrefix` for size order and remainder sums, `linkGroups`), `HardLinkGroup` + `LinkOccurrence`, `NodeRecord`, `StorageTreeBuilder` (value type; `appendChildren`, `setDirFacts`, `setRestricted`, `addSmall`, `addLink`, `snapshot`, `finalize`).
  - `StorageTreeOverlay` (post-clean/undo mutations over an immutable tree; persisted as a sidecar), `RestoredEntry`, `StorageOverlayError`.
  - `ReclaimAccumulator` (selection bytes with hard links counted over the union).
  - Scan: `ScanRoot`, `ScanProgress`, `ScanFailure`, `ScanEvent`.
  - Cleanup: `CleanupCategory`, `SafetyTier`, `DeleteMode`, `SizeProvenance`, `OwnerApp`, `CleanupItem`, `CleanupSet` (+ `LinkGroupSize`), `ClassifyOptions`.
  - Clean: `DenyReason`, `SkipReason`, `CleanItemOutcome`, `CleanEvent`, `CleanReport`, `UndoRecord`, `UndoEntry`, `StorageSummary`.
  - `StoragePolicy` (anchor/protected node sets precomputed by the engine so the UI can disable "Move to Trash" without importing `MonitorDiskTools`).
  - Services: `StoragePlatform` (AppKit-backed closures injected into runtime/DiskTools), `StorageActions` (`@MainActor @Sendable` closures, shape of `ProcessActions`, `.noop`).

New target `MonitorDiskTools → MonitorModel` (scanner, classifier, cleaner, cache). UI targets (`MonitorLive`, `MonitorScreens`, `MonitorUIKit`, App) never import it; `scripts/ci.sh` greps for it.

Affects:
- W1: types, enum case, exhaustive switches (`Sampling`, `PageHeader`, `DashboardRoot`, `Sidebar`, `TTIcon`, `GalleryPopover`), goldens `shell-sidebar-calm`, `component-icons`, `component-sidebar`.
- W2a–c: `MonitorDiskTools` fills the builder, classifies, cleans.
- W3a/b/c: `StorageModel` (MonitorLive), runtime composition, mocks.
- W4: Storage page UI, sidebar value, popover link.

Frozen after W1 merges; later changes are addenda to this ICR, routed by the orchestrator.

## Why

The Storage & Cleanup spec adds a dashboard page and a cleanup engine. The engine lives outside the UI targets, so every value crossing the boundary (tree, cleanup items, events, policy, actions) has to be a `MonitorModel` type.
