# Recorded fixtures (W7 T3)

`[RawTick]` recorded on a real Mac by `telltale-probe --record`, in W1's shared format (`RawTick.fixtureEncoder`):
a JSON array, ISO 8601 UTC dates with milliseconds, keys sorted. Replayed by `RecordedFixtureTests` through the real
`SamplingEngine` (`FixtureReplay`).

| File | Recorded | Command |
|---|---|---|
| `idle.json` | MacBook Pro 14" 2021, M1 Max (8P + 2E), macOS 26; 10 × 1 s interactive; no synthetic load (the machine runs parallel build agents, so "idle" means "nothing added by the recorder") | `scripts/probe.sh --record …/idle.json --ticks 10 --interval 1 --mode interactive --trim-idle` |
| `load-8core.json` | same; 8 × `yes > /dev/null` started 2 s before (≈ 8 cores, grouped under the terminal app) | `… --record …/load-8core.json --ticks 10 --interval 1 --mode interactive --trim-idle` |
| `many-helpers.json` | same; Electron/Chromium apps with helpers (Arc 25, Claude 14, Discord 8) plus a swift build starting mid-recording; Processes page visibility (`.processTable` → `ps` RSS for restricted pids) | `… --record …/many-helpers.json --ticks 8 --interval 1 --page processes --trim-idle` |
| `sleep-wake.json` | **pending** — needs a user-triggered sleep during the recording (the recorder must not sleep a shared machine) | `… --record …/sleep-wake.json --ticks 20 --interval 1 --mode interactive --trim-idle`, then close the lid / Apple menu › Sleep for ≥ 15 s mid-way |

## Trimming (`--trim-idle`)

A busy Mac has ~950 processes and ~780 coalitions: ~450 KB per tick, so 20 raw ticks would be ~9 MB. The 2 MB cap is
met by dropping rows that never change during the recording, which leaves every delta unchanged:

- coalitions kept: those whose CPU, energy or disk counters change;
- processes kept: those whose counters change, or that appear mid-recording with non-zero counters (the engine counts a
  newborn's counters in full); every restricted member and the leader of a kept coalition (residual targets); pids seen
  by the GPU or network sensors; and the responsible process of anything kept (grouping);
- a kept coalition's `memberPIDs` and `rootMemory` are filtered to kept pids.

Dropped rows have zero deltas, so per-app CPU/energy/disk, coalition residuals and system totals are identical. At
record time the probe replays the full and the trimmed recording through `FrameAssembler` and prints the worst
difference; all three files: 0.0000 % app CPU, 0.0000 % Σ app CPU, 0 system CPU, 0.0000 W. What does change: app
memory sums and process/app counts (dropped idle rows are gone).

Recorded on the developer's machine: process names, paths and user names are the recorder's.
