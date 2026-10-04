# W3c progress (storage mocks)

## Plan
T1 MockStorageState, T2 ActionLog kinds + storageActions, T3 MockPipeline.storageActions. Single commit (tasks are interdependent for compilation).

## Done
See commit `feat(storage-mocks): ...` on ws/storage-w3c.

## Next
W3b: add `var storageActions: StorageActions { get }` to RuntimePipeline (MockPipeline already has the `let`).

## Interface deltas (final signatures)
- `MockStorageState` `Sources/MonitorMocks/MockStorageState.swift:6`; `Kind` `:7`; `home` `:9`; `make(_:referenceDate:)` `:27`. Fields as brief.
- `MockDataProvider.storageActions(log:state:)` `Sources/MonitorMocks/MockDataProvider.swift:274`.
- `ActionLog.Kind` += scan, clean, cancelClean, undo, emptyTrash, trash, ignore, unignore (`ActionLog.swift:8`); `storageItemIDs` `:38`.
- `MockPipeline.storageActions: StorageActions` `Sources/MonitorRuntime/MockPipeline.swift:15` (state `.map`, own `ActionLog`).
- Fixture: 21 items in `.map/.cleanup/.noFDA`; ids 1-21 in category order (caches 1-6, leftovers 7-8, largeOld 9-12, developer 13-20, trash 21). In use: id 4 (Chrome). Running: id 1 (Spotify). Ignored: id 6 (Figma). Same-owner pair: 2+3 (Slack, userCaches), 13+14 (Xcode, developer). Evict: 12. Docker `.none`: 19. Simulators `.simctl` nodeID nil: 20. Hard-link group across ids 15+16 (node_modules). Keep-parent caches: 1-6, 13, 14, 18, 21.
- `.noFDA`: Containers, Safari, Group Containers, AddressBook restricted (empty), Mail/Messages restricted in all states; Docker item (19) absent there since it lives in Containers.
- `.map` and `.cleanup` data are identical (kind differs only).

## Behavior choices not in brief
- `clean` logs every input item (including in-use ones); `.none`-mode items yield `skip: .notPermitted`.
- `.freed` = Σ detached of remove/simctl/evict items (not trash), omitted when 0; report `freedBytes` excludes evicted (own field).
- `scan` yields the state's own tree/set when it has a cleanup set, else `make(.map)`; `.partial` is the `.scanning` snapshot.
- `.scanning` tree is `snapshot()`, whose `scanDate` is `Date()` (builder API); only tree arrays are deterministic.
- `cancelClean` target is "" ; `undo` target is the record UUID string.

## Requests
None.

## Not verified
- Visual quality of the fixtures in Space Map screenshots (W4).
- Node count (~1.5-2k) estimated, not measured.

## Blockers
None.
