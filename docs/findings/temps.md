# M0 Findings (M1 Max, macOS 26.5)

## temps — IOHID

- Status: partial success. Sensor read path works fully; the curated CPU‑P /
  CPU‑E / GPU split from the brief does **not** hold on this machine/OS — see
  Mapping below.
- Client type: full (`IOHIDEventSystemClientCreate` succeeded; never fell
  back to `IOHIDEventSystemClientCreateSimpleClient`).
- Sensors: 64 HID services matched `{PrimaryUsagePage: 0xff00, PrimaryUsage:
  5}`. 63 return a temperature event; 1 service has no `Product` name (`"?"`)
  and never returns an event on any run (3/3 repeats) — treat as a stuck/dead
  service and skip it (see Garbage below). Of the 63 live readings there are
  only **28 distinct sensor names**; every name except `NAND CH0 temp` is
  reported by 2 duplicate services (`PMU tdie1` and `PMU tdie2` by 4), each
  returning a very slightly different value (e.g. two `PMU tdie1` reads:
  61.2 °C / 62.8 °C in the same pass). Average the duplicates per name before
  using a value; do not just take the first.
- Cost (M1 Max, 64 services, machine already busy — see Concurrent load
  below):
  - Service enumeration alone (`IOHIDEventSystemClientCopyServices`):
    ~30–40 **microseconds**. Negligible.
  - Full read (fresh enumerate + `Product` name + event for all 64
    services): ~63–139 ms across runs (typical ~65–78 ms idle, up to 139 ms
    once observed under synthetic load — see Notes).
  - Cached read (reuse the service array from the first enumeration, skip
    re-enumerating, just re-read name + event for all 64): ~60–80 ms —
    barely cheaper than the full read. **Enumeration is not the expensive
    part; the ~1 ms/service `IOHIDServiceClientCopyEvent` IPC round trip is.**
    Caching the service list saves microseconds, not milliseconds — cache it
    for correctness/stability (service order, avoiding churn) more than for
    speed.
- Header conflict: none. Checked
  `IOKit.framework/Headers/hidsystem/{IOHIDEventSystemClient,IOHIDServiceClient}.h`
  (the exact two files `IOKit.hidsystem` re-exports, confirmed against the
  framework's `module.modulemap`) for every symbol/typedef the brief adds
  (`IOHIDEventRef`, `IOHIDEventSystemClientCreate`,
  `IOHIDEventSystemClientSetMatching`, `IOHIDServiceClientCopyEvent`,
  `IOHIDEventGetFloatValue`) — none are declared publicly, so
  `HIDPrivate.h` was written verbatim as given in the brief. No fix needed.

### Mapping — does NOT match the brief's assumption

The brief expected sensor names like `pACC …`/`eACC …`/`PMU tdie…` that
self-identify P-core vs E-core vs GPU. On this M1 Max + macOS 26.5, the
`Product` names for every compute-adjacent sensor are generic and carry
**no P/E/GPU tag at all**:

```
PMU tcal            (×1 name, flat, identical both runs — a calibration constant, not a live reading)
PMU tdieN  N=0..10  (11 names, "die temperature" — CPU+GPU silicon, unsplit)
PMU tdevN  N=1..8   (8 names, "device" thermal points — unsplit)
PMU TPxs / TPxg     (6 names: TP0s, TP1g, TP1s, TP2g, TP2s, TP3g — "thermal pad", s/g suffix,
                     NOT a symmetric s+g pair per index — hypothesized GPU-side(g)/SoC-side(s)
                     split, tested below and NOT confirmed)
NAND CH0 temp       (1 name — SSD)
gas gauge battery   (1 name — battery)
```

Concrete pattern mapping actually usable on this hardware:

- **SSD** = `name.hasPrefix("NAND")` — validated (flat/negative delta under CPU
  load, see below).
- **Battery** = `name.contains("gas gauge battery")` — validated (flat under a
  20 s CPU‑only burst; battery has too much thermal mass to react that fast).
- **SoC/PMU (CPU+GPU unsplit)** = `name.hasPrefix("PMU tdie") ||
  name.hasPrefix("PMU tdev") || name.hasPrefix("PMU TP") ||
  name.hasPrefix("PMU tcal")` — validated as compute-adjacent (rose under
  load, see below), but **CPU‑P / CPU‑E / GPU could not be separated within
  this bucket** — see next paragraph.
- **CPU P-cores / CPU E-cores / GPU**: **not populated**. No name pattern
  distinguishes them. Tried the `TPxs`/`TPxg` suffix as an SoC(s)/GPU(g)
  hypothesis; the under-load delta shows `TP1g`/`TP2g`/`TP3g` (+1.1/+1.1/+0.9 °C)
  essentially indistinguishable from `TP0s`/`TP1s`/`TP2s` (+0.9/+0.9/+1.0 °C)
  under a CPU-only load — the hypothesis is not supported by this data. Two
  `tdev` sensors (`tdev4`: 39.7→40.1 °C, `tdev5`: 41.5→41.8 °C) run ~15-20 °C
  cooler than every other compute sensor and rose the least in absolute terms
  — a plausible E-core-cluster or low-power-domain candidate — but this is a
  single, weak, unreplicated signal (see caveats) and is **not** encoded in
  the spike's grouping code; recording it here only as a lead for whoever
  revisits this. Recommendation: get the CPU‑P/E/GPU split from
  `spike-ioreport`'s named energy channels instead (IOReport channel names on
  this SoC do carry P/E/GPU tags per that spike) and treat HID temps as a
  coarse whole-chip/SSD/battery-only source.
- **Airflow/ambient**: none of the 64 matched services expose anything
  resembling a fan or ambient/case sensor under this matching dictionary
  (`{0xff00, 5}`). Not present in this dataset.

### Under-load delta (confirms SoC/PMU bucket; does not confirm sub-split)

Two paired runs (idle baseline, then 8× `yes >/dev/null &` on this 8P+2E
machine for 20 s, `swift run` immediately after, `killall yes`), raw
per-service values averaged per name first:

| bucket (deduped, averaged) | baseline avg/max | +20s load avg/max | Δavg |
|---|---|---|---|
| SoC/PMU (26 names) | 59.1–59.3 / 62.8–63.6 °C | 60.1 / 64.3 °C | +0.8 to +1.0 °C |
| SSD (NAND) | 47–49 °C | 46 °C | ~0 (noise; not load-reactive, as expected) |
| Battery (gas gauge) | 38.2–39.3 °C | 38.4–39.5 °C | ~0 (too slow to react in 20 s) |

Per-name deltas ranged from **+0.0 °C** (`PMU tcal`, `NAND CH0 temp` — both
flat, `tcal` bit-for-bit identical both runs, confirming it is a fixed
calibration value not a live sensor) up to **+2.1 °C** (`PMU tdev3`). This
confirms the SoC/PMU bucket as a whole is compute-adjacent and reactive; the
signal is too weak and too uniform across `tdie`/`tdev`/`TP` names to further
split by cluster.

**Concurrent load**: the M0 plan runs other spikes in parallel worktrees on
this same machine. `uptime` showed load averages of **9.48 → 19.65** and
**~10.5 → 14.8** around these two load tests (`for i in $(seq 8); do yes
>/dev/null & done`, i.e. our own 8-core burst only adds ~8 to that number) —
meaning baseline temps here (59–64 °C "idle") are already elevated by
concurrent background work from other sessions, not this spike alone. This
raises the floor and compresses the delta our synthetic load produces,
which is the most likely reason the P/E/GPU split didn't separate cleanly
above (heat from concurrent work on other cores may already be smeared
across the whole SoC by the time we sample). A clean re-run of this delta
test in isolation (no concurrent spikes) is recommended before trusting any
future P/E/GPU attempt on this sensor family.

### Garbage/stuck sensors to filter

- Exactly 1 of 64 matched services (consistent across 3 repeated runs) has
  no `Product` name (falls back to `"?"`) and `IOHIDServiceClientCopyEvent`
  always returns `nil` for it. Filter: skip any service whose event copy
  fails; don't count it as a sensor.
- All 28 live sensor names are duplicated by 2 (or 4, for `tdie1`/`tdie2`)
  distinct services returning near-identical but not bit-identical values.
  This is not garbage — average it — but a caller that just takes
  `services.first(where: name)` will get a value with an unnecessary ±1-2 °C
  jitter it doesn't need to.

### Notes / gotchas

- `POSIXErrorCode` gotcha (from task 1) does not apply here — no direct
  POSIX syscalls in this spike, only IOKit/CF calls that fail via
  `nil`/`Boolean` return, not `errno`.
- One `full read` sample hit 139 ms (vs. typical 65–78 ms) while running
  back-to-back with the load test; likely scheduler contention from the
  8 concurrent `yes` processes rather than a real per-call regression —
  worth re-checking in isolation if the read cost ever needs a tight
  latency budget.

## Fix round 1 — CPU‑P / CPU‑E / GPU split via SMC

Review approved the code but the design needs the P/E/GPU split HID couldn't
give (see Mapping above). Merged `dev` (SMC shim: `Spikes/Sources/CPrivate/{smc.c,include/SMC.h}`,
`spike-smc`; `spike-gpu-apps --load` Metal GPU load generator — see
`docs/findings/smc.md` and `docs/findings/gpu-apps.md`). Added `--delta` (raw
SMC snapshot of all plausible `T*` `flt ` keys, for scripted before/after
diffing) and `--curated` (fast curated-key read + HID cross-check) modes to
`spike-temps`; default (no flags) behavior is unchanged.

### Method

3 targeted loads, ~38–40 s each, `swift run --scratch-path .build-temps
spike-temps --delta` immediately before and immediately after each, `uptime`
checked before every phase:

1. **E-core-only**: `taskpolicy -c background yes >/dev/null &` × 4 (background
   QoS hints the scheduler at the 2 E-cores).
2. **P-core**: plain `yes >/dev/null &` × 8 (one per P-core; default QoS,
   scheduler keeps 8 threads on the 8 P-cores under normal contention).
3. **GPU**: looped `swift run spike-gpu-apps --load` (each invocation only
   sustains its Metal busy-loop for ~1.3–2 s before the process exits — the
   GPU thread isn't joined — so a single invocation is not a 40 s load; looped
   ~20× back-to-back in the background for the full window instead).

All `yes`/loop PIDs were captured into a bash array at launch (`pids+=($!)`)
and killed by exact PID (`kill "$p"`), never `killall`/`pkill -f yes` — this
machine runs other agents' spikes concurrently and a blunt kill would hit
their processes too (this is exactly what happened to a *different* session
during the original SMC spike, per `docs/findings/smc.md`). Verified no `yes`
processes were left running after each phase and after this whole run.

**Cross-run confound found and corrected**: the first pass ran E→P→GPU with
only ~20–25 s cooldowns between phases and diffed everything against one
baseline taken before phase 1. By the GPU phase, that produced inflated,
untrustworthy GPU deltas (+20 to +32 °C, larger than even the P-core phase) —
residual heat from the P-core phase hadn't fully dissipated in 20–25 s. A
45 s cooldown check showed the machine recovers to within ~2 °C of the
original baseline, so the GPU phase was **re-run in isolation** (fresh
baseline right before it, no preceding load) for the numbers below. The E-core
and P-core deltas below are from the original (first, least-confounded) pass,
since they ran earliest with minimal accumulated heat.

### Delta evidence (baseline → load, °C)

| SMC family | n | dE (E-core-only) | dP (P-core) | dG (GPU, isolated re-run) |
|---|---|---|---|---|
| `TC1x` (TC10-13) | 4 | +2.5 to +3.0 | **+13.6 to +16.0** (highest) | +17.5 to +18.2 |
| `TC2x` (TC20-23) | 4 | -0.6 to +2.0 (~noise) | +8.8 to +9.3 | +23.4 to +24.8 |
| `TC3x` (TC30-33) | 4 | +0.5 to +1.6 | +8.5 to +10.2 | +23.4 to +25.1 |
| `TC4x` (TC40-43) | 4 | +0.7 to +0.9 | +5.5 to +6.4 (lowest) | +15.9 to +17.9 (lowest) |
| `TC5x` (TC50-53) | 4 | +0.2 to +0.4 (lowest) | +5.4 to +5.6 (lowest) | +16.8 to +17.4 |
| `Tg0*` (8 keys) | 8 | +0.0 to +0.6 | +6.9 to +8.2 | **+25.6 to +25.7** (tightest, cleanest signal in the dataset) |
| `Tp0*` (30 keys) | 30 | +2.0 to +7.6 | +11.4 to +17.7 | +15.0 to +28.6 (reacts to everything, most of all) |
| `Td0*` (18 keys, SSD candidate) | 18 | +0.2 to +1.4 | +5.9 to +7.8 | +15.7 to +19.5 |
| `TB*T` (battery) | 3 | -0.1 to -0.3 | -0.3 to -0.6 | -0.1 to -0.2 |
| `TAOL` (ambient) | 1 | +0.1 | +0.2 | +0.0 |

### Final mapping

| Curated group | Source | Keys | Confidence | Evidence |
|---|---|---|---|---|
| **CPU P-cores** | SMC | `TC1x, TC2x, TC3x` (12) | Medium | Highest 3 responders to the P-core-only test (+8.5 to +16.0 °C) vs the other 2 TC groups (+5.4 to +6.4 °C). `TC1x` itself also reacts to the E-core-only test (+2.5-3.0, more than any other TC group) — likely a shared/central CPU-complex probe rather than purely P-specific; grouped as P because its P-reactivity dominates its own E-reactivity by ~5x. |
| **CPU E-cores** | SMC | `TC4x, TC5x` (8) | Low-medium | Weakest responders to **all three** load types (P, E, and GPU) of the 5 TC groups — best candidate for the 2 low-power E-cores by elimination (physically distant from the hot P/GPU blocks, and E-cores draw little power even saturated), but no single load type singles them out strongly, so this is elimination-based, not a positive ID. |
| **GPU** | SMC | `Tg04,05,0C,0D,0K,0L,0S,0T` (8) | **High** | By far the cleanest signal: near-identical +25.6/+25.7 °C across all 8 keys under isolated GPU load, ~0-8 °C under CPU-only loads. |
| **SoC** | HID (Task 4, unchanged) | `PMU tdie*/tdev*/TP*/tcal` | Medium (as before) | Kept as-is; SMC's `Tp0*` family (30 keys) reacts to *every* load tested, more strongly than TC — offered in `--curated` output as an SMC cross-reference for "general board heat," but not wired in as the production SoC source (out of scope for this fix; would need its own validation pass). |
| **SSD** | HID (Task 4, unchanged) | `NAND CH0 temp` | See caveat | **SMC cross-check disagrees**: HID NAND=39.0 °C vs SMC `Td0*` avg=55.5 °C at the same instant (~16.5 °C apart), and `Td0*` rises +15.7 to +19.5 °C under *GPU* load with zero I/O — either `Td` isn't actually the physical NAND (smc.md's naming was a guess), or it's a SoC-embedded storage-controller die that picks up conducted heat from the hot SoC, not a self-heating-from-I/O sensor. Kept HID's explicit "NAND" name as the production source; flagging `Td` as unresolved, not the same physical sensor. |
| **Battery** | HID (Task 4, unchanged) | `gas gauge battery` | High | **SMC cross-check agrees**: HID=37.4 °C vs SMC `TB0T/TB1T/TB2T`=37.6/37.6/37.1 °C at the same instant — within noise. Both near-flat under all 3 loads (battery has too much thermal mass to react in 40 s). |
| **Ambient** | SMC | `TAOL` | High | Only ambient-like source found (HID has none, confirmed in Task 4). Coolest reading by far (~29 °C vs 37-90 °C for everything else) and essentially flat under all 3 loads (+0.0 to +0.3 °C) — consistent with an outside-case/intake sensor, not an internal one. |

Other SMC families seen but not classified (out of scope for the curated
groups asked): `Th*`/`TH0*` (heatpipe/hotspot candidates, wide range), `Tm0*`
(memory? paired-duplicate pattern like HID's duplicate services), `TPD*` (21
keys, very tight 49-50 °C band — proximity/case-skin candidate), `Ta*`,
`TRD*`, `TS*`, `TV*`, `TW0P` (unidentified).

### Perf mitigation

| Read strategy | Keys/services | Cost |
|---|---|---|
| HID full read (Task 4, `spike-temps` default) | 64 services | 63-67 ms |
| SMC full enumeration (`--delta`, all plausible `T*` keys) | 217 | 477-553 ms |
| **SMC curated read (`--curated`, exact key names, no enumeration)** | 80 | **27-38 ms** |

The curated SMC read (exact `smc_read` calls by name, skipping
`smc_key_at`/`#KEY` enumeration entirely) is ~15-18x cheaper than a full SMC
sweep and ~2x cheaper than the HID full read — confirms smc.md's
recommendation (enumerate once, cache the key list, never re-enumerate every
tick) and extends it: for a fixed curated set, skip enumeration altogether
and just call `smc_read` by name every tick.

**Recommended cadence: 2 s.** Combined worst-case per-tick cost (SMC curated
~40 ms + HID full read ~70 ms, if both sources are polled every tick for the
cross-check) is ~110 ms — under 6% of a 2 s budget, leaving comfortable
headroom. Even a 1 s cadence would be safe (~11% of budget); 2 s is chosen
to match the M0 plan's general sensor-refresh convention, not because the
read cost demands it.

### Commands used (for reproduction)

```
git merge dev
swift build --scratch-path .build-temps
swift run --scratch-path .build-temps spike-temps --delta   # baseline / after-load snapshots
swift run --scratch-path .build-temps spike-temps --curated # final curated read + HID cross-check
```
