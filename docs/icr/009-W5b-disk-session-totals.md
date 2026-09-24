# ICR 009 (W5b): per-process disk session totals

Number is provisional; the controller may renumber.

## What

Add two fields to `ProcessSample`, filled by the engine (W1):

```swift
public var diskReadSession: UInt64?, diskWriteSession: UInt64?   // bytes since Telltale started
```

The engine keeps a baseline of `ri_diskio_bytesread/written` per `ProcessID` the first time it sees each pid:
- A pid whose `startTimeUs` is at or after the engine start gets baseline 0.
- Any other pid gets the counter value at its first sample. The engine samples processes in the background from launch, so this baseline is exact to within one tick.

`session = lifetime − baseline`. Baselines are dropped when the pid exits. This could live beside `SessionAccumulator`, which today has no disk fields. `diskReadTotal/diskWriteTotal` keep their current meaning, the lifetime counters.

Affects:
- W0a: `ProcessSample` (additive, Codable default nil).
- W1: `ProcessAssembler` / `SessionAccumulator`.
- Wm: mocks set the session fields to what they put in `diskReadTotal` today.
- W5b: the Disk page reads the new fields.

## Why (CP2 bug)

Disk "Written (session)" showed lifetime totals, e.g. 171.40 GB 12 s after launch. DESIGN §3.11 says: "Session totals count since Telltale launched."

The UI only sees processes while a page is presenting. The W5b interim (`DiskSessionBaselines` in `DiskPage.swift`, `TODO(ICR 009)`) handles the two cases differently:
- A process that started after Telltale counts in full.
- A process that predates Telltale counts from when the Disk page first saw it. Those values carry the tooltip "Counted since Telltale first saw this process; earlier I/O this session isn't included".

Only the engine can make the second case exact.
