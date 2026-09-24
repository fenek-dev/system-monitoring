# ICR 009 (W5a): `HistoryMetric.memPressureLevel` for the level-colored Memory pressure chart

Number is provisional; the controller may renumber. **Accepted as ICR-12** (W7 a9ba2e7), with a ruling that
replaces the "max" aggregate below: buckets keep the time-weighted average; the consumer maps v > 2.5 → critical,
v > 1.0 → warning, else normal. `MemoryPage` reads it (interim removed).

## What

Add one `HistoryMetric` case (additive, ARCHITECTURE §9 — no store migration, ALTER-ADD at open):

```swift
case memPressureLevel      // MemoryPressureLevel.rawValue (1 normal, 2 warning, 4 critical); sources [.memory]
```

- `MonitorModel/Basics/Metrics.swift`: the case, `sources` → `[.memory]`, `category` → `.memory`.
- W1 assembly (`SystemMetrics`): `m[.memPressureLevel] = memory.pressureLevel.map { Double($0.rawValue) }`
  (same pattern as `.thermalPressure`). Wm `MockDataProvider.makeMetrics` likewise.
- Store rollups: bucket aggregate **max** (like temperatures), so a bucket that touched warning stays warning.

## Why

DESIGN §3.7.3: the Memory pressure area is colored by the **OS pressure level** per sample ("the span from sample
i to i+1 takes the level of sample i"). Only the pressure *percent* (`.memPressure`) is recorded, so neither the
Live ring nor the store can say which level each past sample had. Deriving it from fixed % thresholds is exactly
what DESIGN §6.16 rules out.

## Interim (W5a, until landed)

`MemoryPage` colors every segment with the **current** level (correct whenever the level has not changed within
the window, e.g. every calm render). The drawing code already segments by a per-sample level array; switching to
the new metric is a one-line change (`MemoryPressureChart.levels`).

Affects: W0a (Model), W1 (assembly), W2 (rollup aggregate), Wm (mock metrics), W5a (consumer).
