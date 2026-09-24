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
