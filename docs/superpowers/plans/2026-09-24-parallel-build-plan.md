# Telltale — Parallel Build Plan (M1–M6)

> **For agentic workers:** one workstream per agent, each in its own git worktree. REQUIRED SUB-SKILLS: superpowers:using-git-worktrees, superpowers:test-driven-development (W1, W2, W3 layout math, W6 parse layers), superpowers:verification-before-completion. Steps use `- [ ]`.

**Goal:** build Telltale (SPEC.md) with 4–6 agents working concurrently against the locked interfaces in `docs/ARCHITECTURE.md` §5.
**Architecture:** `docs/ARCHITECTURE.md` (binding). Design: `docs/design/artboards/*.dc.html`, `docs/design/DESIGN.md`, reference PNGs `docs/design/reference/*.png` (W3 T0).
**Inputs pending:** `docs/findings/*.md` from M0 (gate W6 streams).

---

## 0. Rules for every stream

- **Worktree:** `git worktree add ../telltale-<id> -b ws/<id>-<slug> dev` (e.g. `../telltale-w1`, `ws/w1-engine`). Work, commit, and test only there. Each worktree has its own `.build/` and `TELLTALE_DATA_DIR=.build/data` (set by `scripts/run.sh`), so apps/DBs from different worktrees don't collide. Quit other Telltale instances before `scripts/run.sh` (two status items confuse checks).
- **Ownership:** edit only files your stream owns (§1). Need a Model/Package change → ICR (`docs/icr/NNN-<id>-<slug>.md`, ARCHITECTURE §9), keep going with a local extension.
- **Merging:** small PRs per task group, rebased on `dev`, fast-forward. Pre-merge: `scripts/ci.sh <YourTestSuites>` (= `swift build` all targets + `scripts/build.sh` + listed suites). The integrator (W7 owner, or the lead before W7 starts) merges.
- **Tests (user rule):** TDD loop reruns only the failing tests + suites whose sources you touched. Full `swift test` only at integration checkpoints (reason: shared infrastructure) or when asked — state which.
- **Output budget:** pipe builds/tests through the scripts (they `tail`/`grep`). Never paste > ~100 lines.
- **Commits:** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Perf numbers are advisory:** report them; don't tune to them unless a checkpoint says the budget is blown by > 2×.

---

## 1. Ownership matrix (no file has two owners)

| Stream | Owns (paths relative to repo root) |
|---|---|
| **W0** foundation (then integrator) | `MonitorCore/Package.swift`, `MonitorCore/Sources/MonitorModel/**`, `.gitignore`, `scripts/{gen,build,test,ci,render}.sh`, `MonitorCore/Sources/CPrivate/shim.c`, `MonitorCore/Sources/MonitorSensors/{LiveSensorFactory.swift,Support/**}`, `MonitorCore/Sources/MonitorMocks/**`, `MonitorCore/Tests/MonitorEngineTests/ModelCodableTests.swift` |
| **W1** engine | `MonitorCore/Sources/MonitorEngine/**`, `MonitorCore/Tests/MonitorEngineTests/**` (except `ModelCodableTests.swift`, `Fixtures/recorded/**`) |
| **W2** store | `MonitorCore/Sources/MonitorStore/**`, `MonitorCore/Tests/MonitorStoreTests/**` |
| **W3** UI kit | `MonitorCore/Sources/MonitorUIKit/**`, `MonitorCore/Tests/MonitorUIKitTests/**`, `MonitorCore/Sources/telltale-render/**`, `docs/design/reference/**` |
| **W4** app shell | `project.yml`, `App/**`, `scripts/{run,install}.sh`, `MonitorCore/Sources/MonitorScreens/Shell/**`, `MonitorCore/Tests/MonitorScreensTests/Shell*` + `__Snapshots__/shell-*` |
| **W5a** screens A | `MonitorScreens/Popover/**`, `MonitorScreens/Pages/{Overview,CPU,GPU,Memory,Network}Page.swift`, `MonitorScreensTests/{Popover,Overview,CPU,GPU,Memory,Network}*` + `__Snapshots__/{popover,overview,cpu,gpu,memory,network}-*` |
| **W5b** screens B | `MonitorScreens/Pages/{Thermals,Power,Disk}Page.swift`, `MonitorScreens/Pages/Processes/**`, `MonitorScreens/Pages/History/**`, `MonitorScreensTests/{Thermals,Power,Disk,Processes,History}*` + `__Snapshots__/{thermals,power,disk,processes,history}-*` |
| **W6a** sensors: process & host | `MonitorSensors/Process/**`, `MonitorSensors/Host/**`, `CPrivate/include/{Responsibility,Sysmon}.h`, `MonitorSensorsTests/{Process,Host,Memory,Device,Assertion}*` |
| **W6b** sensors: SoC, thermal, power | `MonitorSensors/{SoC,Thermal,Power}/**`, `CPrivate/include/{IOReport,HIDPrivate,SMC}.h`, `CPrivate/smc.c`, `MonitorSensorsTests/{IOReport,GPUClients,HID,SMC,Thermal,Battery}*` |
| **W6c** sensors: network | `MonitorSensors/Network/**`, `CPrivate/include/NStat.h`, `MonitorSensorsTests/{NStat,Interface,WiFi,Latency,ReverseDNS}*` |
| **W6d** sensors: disk | `MonitorSensors/Disk/**`, `MonitorSensorsTests/{DiskIO,Volume,SMART}*` |
| **W7** integration & perf | `MonitorCore/Sources/MonitorRuntime/**`, `MonitorCore/Sources/telltale-probe/**`, `MonitorCore/Tests/MonitorRuntimeTests/**`, `MonitorCore/Tests/MonitorEngineTests/Fixtures/recorded/**`, `scripts/{probe,perf}.sh`, `docs/perf/**` |

`MonitorScreens/Shell/ScreenCatalog.swift` (screen × scenario registry used by `telltale-render`) is W4's; W0 writes it complete, so W5 never edits it.

---

## 2. Dependency graph and slots

```
                 ┌──────────── W1 engine ───────────────┐
                 ├──────────── W2 store ────────────┐   │
W0 foundation ───┼──────────── W3 UI kit ──┐        │   │
 (all stubs,     ├──────────── W4 shell ───┤        │   │
  mock app runs) ├── W5a screens A ◀── W3 A┤        │   │
                 └── W5b screens B ◀── W3 A┘        │   │
                                                    ▼   ▼
  docs/findings/* ──▶ W6a ─┐                     W7 integration (live pipeline, probe, fixtures, perf)
                  ──▶ W6b ─┼──▶ (each merges independently; W7 wires nothing per sensor: LiveSensorFactory already references them)
                  ──▶ W6c ─┤
                  ──▶ W6d ─┘
```

Hard dependencies (must be merged first):

| Stream | Needs merged | Soft (nice to have) |
|---|---|---|
| W1, W2, W3, W4 | W0 | — |
| W5a, W5b | W0 | W3 phase A (T1–T5) for real visuals; stubs compile from day 1 |
| W6a/b/c/d | W0 + its `docs/findings/*.md` | W7 T2 (probe `--sensor`) — W0's probe is enough to start |
| W7 T1 live pipeline | W0, W1 T12–T13 | W2 (uses stub store until merged) |
| W7 perf / CP2+ | W7 T1, W6a | W6b–d |

Suggested slot plan (6 agents; a slot takes the next stream when free):

| Slot | Day 0 | Day 1–3 | Then |
|---|---|---|---|
| 1 | W0 (lead) | W1 | W7 |
| 2 | — | W2 | W6d → W6c |
| 3 | — | W3 | W6b |
| 4 | — | W4 | W6a (if findings ready earlier, W6a preempts W4's later tasks) |
| 5 | — | W5a | W5a polish / CP5 |
| 6 | — | W5b | W5b polish / CP5 |

---

## W0 — Foundation (lands first, single agent)

**Goal:** everything compiles; every shared type exists exactly as in ARCHITECTURE §5; the app builds from CLI and runs in mock mode; every other stream can start with zero edits outside its own paths.
**Owns:** see §1 (and, transiently, initial versions of every stub file listed below; ownership transfers to the named stream at merge).
**Consumes:** `Spikes/Sources/CPrivate/**`, ARCHITECTURE.md. **Produces:** all interfaces, stubs, scripts, mock runtime.
**Depends on:** nothing.

- [ ] **T0.1 Scripts + ignore.** `scripts/{gen,build,run,test,ci,render,probe,perf,install}.sh` per ARCHITECTURE §1 (probe/perf/install may be thin; W7/W4 finish them). `.gitignore` += `Telltale.xcodeproj/`, `.build*/`, `MonitorCore/.build/`.
  Accept: `bash -n scripts/*.sh` clean; `scripts/test.sh X` prints ≤ 25 lines.
- [ ] **T0.2 Package.** `MonitorCore/Package.swift` (tools 6.0, macOS 14, Swift 6 mode except CPrivate) with every target/product/test target from ARCHITECTURE §2, GRDB `from: "7.0.0"`, `privateLinks` on `CPrivate`. Copy all headers + `smc.c` + `shim.c` from `Spikes/Sources/CPrivate`.
  Accept: `cd MonitorCore && swift build 2>&1 | grep -E 'error|Compiling|Build' | tail -3` → `Build complete`.
- [ ] **T0.3 MonitorModel.** All types of ARCHITECTURE §5.1–5.5, 5.7–5.10 with explicit `public init`s (defaults for every field), `Codable`, `Sendable`, `Equatable`; `SystemFrame.empty`, `DeviceInfo.placeholder`, `AlertState.calm`; `UnavailableSensor`, `FixtureSensor`, `SensorSuite.allUnavailable`; `MetricVector`.
  Accept: `scripts/test.sh ModelCodableTests` green (round-trip every top-level type; `MetricVector` NaN ↔ nil).
- [ ] **T0.4 Engine stubs (W1 takes over).** Every public type/func of §5.6 with trivial bodies (return nil/empty; `SamplingEngine` loop that yields `SystemFrame.empty`). **`RingBuffer` and `LiveModel` must work** (basic `apply`: copy fields, append `frame.metrics` to ring buffers, `topApps`, `series`).
  Accept: `swift build`; a smoke test `LiveModelSmokeTests` applies 3 mock frames and reads `series(.cpuUsage)` count 3.
- [ ] **T0.5 Sensor stubs (W6 takes over).** One file per adapter in ARCHITECTURE §2 tree; each `public final class <Name>: Sensor` with the right `Reading`, cadence from §5.4 table, `prepare()` throwing `.unavailable("not implemented")`. `LiveSensorFactory.swift`: `SensorFactory.live` building `SensorSuite` from these classes, honoring `disabled`. `Support/Mach.swift` (`machTicksToNs`, `uptimeNs()`), `Support/CFHelpers.swift`.
  Accept: `swift build`; W0 probe (T0.10) lists 18 sensors, all `unavailable(not implemented)`.
- [ ] **T0.6 Store stub (W2 takes over).** `HistoryStore` actor conforming to both protocols, no-op writes, empty reads; `EmptyHistoryProvider` lives in MonitorUIKit env file (T0.7).
- [ ] **T0.7 UI kit stubs (W3 takes over).** Every signature of ARCHITECTURE §5.11 compiling; placeholder bodies (rounded rect + label); tokens with provisional values from artboard CSS (`#121317` bg, `#f2f2f4` text, `#a8a8b0` secondary, `#0a84ff` accent); `EnvironmentValues+Telltale.swift` (`@Entry` keys); `SnapshotRenderer.hosting` + `writePNG` **working** (render CLI needs it).
- [ ] **T0.8 Mocks.** `MockDataProvider` with all `MockScenario`s (numbers from MenuBar/Main/CPU/… artboards: M4 Pro 8P+4E, 24 GB, Xcode 212.4 % 3.82 GB, FCP 96.1 %/9.2 % GPU, Safari, WindowServer, com.docker.backend, Dropbox, Slack, Music, mds_stores); deterministic via seeded LCG like the artboards; `MockHistoryProvider` (30 d synthetic with History.dc bumps and events); `ActionLog` + recording `ProcessActions`.
  Accept: `scripts/test.sh MockDataProviderTests` — same seed ⇒ identical frames; `thermalFair` ⇒ `alert.level == .elevated`, arc `.thermals`, culprit "Final Cut Pro".
- [ ] **T0.9 Screens stubs.** `NavigationModel` (full), `ScreenCatalog` (all screens × scenarios + sizes, `LiveModel.mock(_:ticks:)`), `DashboardRoot` (sidebar list + page switch), `PopoverRoot`, `SettingsView`, and one placeholder view per page (`OverviewPage`, `CPUPage`, …, `ProcessesPage`, `AppInspector`, `HistoryPage`, `TimeTravelTreemap`), each `public init()` reading env.
- [ ] **T0.10 Runtime + CLIs.** `TelltaleRuntime.make(mode:)`: mock path complete (MockDataProvider stream → LiveModel; honors visibility interval 1 s/5 s and pause); live path = mock + `os_log` warning (W7 replaces). `telltale-render --screen <id> --scenario <s> --out <png>` and `--all --out-dir`. `telltale-probe --list | --sensor <id> --ticks N` (prepare + sample, print status, cost, 200-char description).
  Accept: `scripts/render.sh overview calm` writes a 2560×1720 PNG; `scripts/probe.sh --list` prints 18 rows.
- [ ] **T0.11 App shell minimal (W4 takes over).** `project.yml` (ARCHITECTURE §1), `App/Info.plist`, `main.swift`, `AppDelegate` (status item with `StatusGlyphRenderer` image; click toggles a panel hosting `PopoverRoot`; `AppCommands.openDashboard` opens a window hosting `DashboardRoot`), `AppEnvironment` parsing `--mock`.
  Accept: `scripts/build.sh` → `BUILD SUCCEEDED`, prints app path; `otool -L <app>/Contents/MacOS/Telltale | grep -E 'IOReport|sysmon|NetworkStatistics'` shows 3 links.
- [ ] **T0.12 Verification = CP0** (§Integration). Full `swift test` (reason: first run of shared infrastructure). Merge to `dev`, tag `cp0`.

---

## W1 — Engine: rates, grouping, assembly, alerts, live model (TDD)

**Goal:** deterministic, fixture-tested pipeline RawTick → SystemFrame → HistoryRecord/events; the sampling actor; the UI-facing `LiveModel`.
**Owns:** `MonitorCore/Sources/MonitorEngine/**`, `MonitorCore/Tests/MonitorEngineTests/**` (minus W0/W7 files).
**Consumes:** MonitorModel (§5.1–5.7). **Produces:** §5.6 + §5.7 implementations; `LiveModel` semantics W4/W5 rely on.
**Depends on:** W0. Real-fixture tests (T14) wait for W7 T3.

Every task: write failing test → implement → `scripts/test.sh <Suite>` green.

- [ ] **T1 RingBuffer + LiveHistory.** Fixed capacity, wraparound order, `SeriesPoint` window slicing by time, gap point when dt > 3× interval. Suite `RingBufferTests`, `LiveHistoryTests`.
- [ ] **T2 RateCalculator.** First sight nil; steady rate; counter reset (smaller value) ⇒ nil + rebaseline; zero dt ⇒ nil; prune; reset. Suite `RateCalculatorTests`.
- [ ] **T3 CPUTicks.** Per-core usage, user/system/idle fractions, core count change ⇒ nil. Suite `CPUTicksTests`.
- [ ] **T4 AppResolver + AppGrouper.** Rules of ARCHITECTURE §5.1 (tests build fake `.app` bundles with `Info.plist` in a temp dir): helper → responsible app; nested `.app` → outermost; user non-app → `.process`; root daemon → `.system`; restricted → `.system`; cache hit doesn't touch disk (counter). Suite `AppGroupingTests`.
- [ ] **T5 ProcessAssembler.** `RawProcess` + `GPUClientsReading` + `NetworkFlowsReading` (+ closed bytes) + `SleepAssertionsReading` → `[ProcessSample]`: cpu % = Δns/Δt/1e9×100; energy W = ΔnJ/Δt/1e9; GPU % = ΔgpuNs/Δt; PID reuse (same pid, new startTime) ⇒ no rate; `isCurrentUser`; totals. Suite `ProcessAssemblerTests`.
- [ ] **T6 SystemAssembler.** CPU (clusters from IOReport + host ticks), GPU (IOReport, AGX fallback), memory (used = app + wired + compressed; rates of page/swap ins/outs), network (sum non-loopback interfaces; primary ipv4), thermals (group avg/max, hottest, socAverage = mean of cpu/gpu/soc groups), power (package = cpu+gpu+ane+dram; battery drain = V×A), disk (sum internal drivers; IOPS). Fills `SystemMetrics`. Suite `SystemAssemblerTests`.
- [ ] **T7 FrameAssembler.** Composes T5/T6 + `AppGrouper`; `sensorHealth`; `interval`; `reset()` ⇒ next frame has no rates. Suite `FrameAssemblerTests`.
- [ ] **T8 RecordBuilder.** Threshold per `RecordConfig`; remainder summed into `.other`; system vector copied. Suite `RecordBuilderTests`.
- [ ] **T9 AlertEngine.** Table-driven tests for every row of ARCHITECTURE §5.7: immediate step-up, `stepDownHold` hysteresis, runaway enter after 5 min sustained / exit after 30 s below 80 %, `pulseToken` increments only on entry to critical, nil inputs never raise, paused ⇒ calm + `paused`, culprit selection, emitted `HistoryEvent`s. Suite `AlertEngineTests`.
- [ ] **T10 EventDetector.** App episodes (enter/merge/close, min duration), swap growth, flush on pause. Suite `EventDetectorTests`.
- [ ] **T11 LiveModel.** Phases (collecting until first frame with `interval != nil`; paused), `isPresenting` gate (observed properties unchanged while false; published on flip to true), `topApps` per Category table, `topConsumer`, per-app series only for top 64 apps. Test observation with `withObservationTracking`. Suite `LiveModelTests`.
- [ ] **T12 SensorSlot + CrashCanary.** With `FixtureSensor`: lazy prepare, cadence per mode & demand, `.cached` ages, transient ⇒ stale then nil, 3 failures ⇒ degraded + backoff, unavailable ⇒ retry after 5 min (injected clock), canary marker set/cleared (UserDefaults suite in temp). Suite `SensorSlotTests`.
- [ ] **T13 SamplingEngine.** Custom executor; `sampleOnce()`; loop with test intervals (internal init `intervals:` override, 20 ms); mode switch samples immediately; pause stops sampling + emits paused event and no records; wake resets baselines; `liveFrames` drops stale; records unbounded. Suite `SamplingEngineTests`.
- [ ] **T14 Recorded-fixture replay** (after W7 T3): `FixtureLoader.ticks("idle")`, `("load-8core")`, `("chrome")`, `("sleep-wake")` → invariants: CPU usage ∈ [0,1]; sum of app CPU ≈ system CPU × cores ×100 (±15 %); Chrome helpers grouped under one app; no rate spike after wake. Suite `RecordedFixtureTests`.

**Verification:** `scripts/test.sh MonitorEngineTests` (own target — touched sources). Perf: `FrameAssemblerTests/testAssemble600Processes` measures mean over 100 runs with a 600-process synthetic tick; report ms (target ≤ 2 ms, advisory).

---

## W2 — Store: GRDB, rollups, queries, export (TDD)

**Goal:** `HistoryStore` implementing `HistoryRecorder` + `HistoryProvider` per ARCHITECTURE §5.8.
**Owns:** `MonitorCore/Sources/MonitorStore/**`, `MonitorCore/Tests/MonitorStoreTests/**`.
**Consumes:** MonitorModel History types. **Produces:** live `HistoryStore` for W7; query semantics for W5b.
**Depends on:** W0.

All tests use `.inMemory` (plus `.file(tmp)` where WAL matters) and an injected `now`.

- [ ] **T1 Open + migrate.** Pragmas (WAL, NORMAL, INCREMENTAL auto_vacuum, cache_size), migrator `v1` = schema of §5.8, columns generated from `HistoryMetric.allCases`. Suite `SchemaTests` (columns match enum; reopen idempotent).
- [ ] **T2 Append + flush.** Buffer; flush on `flushInterval` or `flushMaxRecords`; one transaction; app upsert by key; `.other` row; events insert/update (end set later). Suite `WriterTests`.
- [ ] **T3 Raw series.** `series(_:range:.hour/.day,…)` bucketed to ≤ maxPoints (AVG per bucket), gap points where no rows for > 3× bucket, `nil` for NaN columns. Suite `SeriesQueryTests`.
- [ ] **T4 Rollups.** 1 m from raw, 15 m from 1 m, only completed buckets, idempotent re-run, `n` counts, apps absent in some samples averaged as 0. Suite `RollupTests` (avg(raw) == 1 m value within 1e-9).
- [ ] **T5 Retention.** Raw > 24 h, 1 m > 7 d, 15 m > 30 d, events > 30 d deleted; `incremental_vacuum`. Suite `RetentionTests`.
- [ ] **T6 Range routing.** week → 1 m, month → 15 m; boundary where raw has been pruned but 1 m exists. Suite `RangeRoutingTests`.
- [ ] **T7 App queries.** `appSeries`, `appShares(at:)` (bucket containing time; fractions sum to 1 incl. `.other`), `topApps` avg/peak/total, `total` (∫rate dt using interval_ms), `peak`. Suite `AppQueryTests`.
- [ ] **T8 Events + coverage.** `events(in:)` overlap semantics; `coverage()` min..max ts across tables. Suite `EventQueryTests`.
- [ ] **T9 CSV export.** Header, ISO-8601 UTC, range rows, streaming (no full materialization), golden file `Tests/MonitorStoreTests/Golden/export-hour.csv`. Suite `CSVExportTests`.
- [ ] **T10 Robustness.** `flushSync()`; newer `user_version` ⇒ file moved aside + fresh DB; unreadable path ⇒ throws (runtime falls back to in-memory). Suite `RobustnessTests`.
- [ ] **T11 Perf test (advisory).** File DB: 24 h synthetic at 1 s (86,400 system rows, 15 apps each) + maintenance: report flush time per 30 records, maintenance pass time, file size, `series(month)`/`appShares` latency. Suite `StorePerfTests` (tagged, run on request). Record numbers in PR.

**Verification:** `scripts/test.sh MonitorStoreTests`; perf numbers from T11 in PR description (targets: flush < 5 ms, queries < 50 ms, 30-day projection < 200 MB).

---

## W3 — UI kit: tokens, components, charts, treemap, glyph, snapshot harness

**Goal:** every component of ARCHITECTURE §5.11 in the design's visual language; snapshot tooling; reference PNGs.
**Owns:** `MonitorCore/Sources/MonitorUIKit/**`, `MonitorCore/Tests/MonitorUIKitTests/**`, `MonitorCore/Sources/telltale-render/**`, `docs/design/reference/**`.
**Consumes:** MonitorModel, `docs/design/DESIGN.md`, artboards. **Produces:** components for W4/W5; `assertSnapshot`; `telltale-render --compare`.
**Depends on:** W0. Phase A = T0–T5 (unblocks W5 visuals) — merge as soon as done.

- [ ] **T0 Reference PNGs.** Capture the 13 artboards at native size @2x into `docs/design/reference/<Artboard>.png` (browser tool on the canvas link from SPEC.md; fallback `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --hide-scrollbars --force-device-scale-factor=2 --window-size=1280,860 --screenshot=… file://…`). Accept: 13 PNGs, sizes match `canvas.json` ×2.
- [ ] **T1 Tokens.** From DESIGN.md (if not yet written: from artboard CSS; reconcile when it lands). Accept: `TokenTests` (contrast of text on surfaces ≥ 4.5 : 1 for primary/secondary), gallery render.
- [ ] **T2 Fmt (TDD).** Table tests with every number format visible in the artboards ("212.4%", "3.82 GB", "894 MB", "8.1 MB/s", "12 KB/s", "5 h 40 m", "2:41:07", "4.12 GHz", "1,180 MHz", "3,104", "−52 dBm", "—"). Suite `FmtTests`.
- [ ] **T3 Snapshot harness.** `assertSnapshot` (tolerance compare, `TELLTALE_RECORD=1`, failure artifacts), both render paths, `telltale-render --compare <reference.png>` (side-by-side + 50 % overlay PNG), `--gallery`. Suite `SnapshotHarnessTests` (renders a known view twice ⇒ identical; red vs blue ⇒ fails).
- [ ] **T4 TreemapLayout (TDD).** Areas ∝ values (±0.5 %), no overlaps, union == rect, input order preserved, zeros → `.zero`, worst aspect ratio ≤ slice-and-dice's on random inputs (property test, 200 seeds). Suite `TreemapLayoutTests`.
- [ ] **T5 Core components.** `Panel`, `StatTile`, `MetricValue` ("—" + `.help`), `Sparkline` (Canvas; gaps), `RangePicker`, `AppIcon` (+ `NSCache`), `EmptyState`, `PageScroll`. Snapshot each in `ComponentSnapshotTests` after visual check vs Main/CPU artboards.
- [ ] **T6 Charts.** `ChartSegments` (split series at nil — TDD, `ChartSegmentsTests`); `LiveChart` (60 s axis labels "60 s ago · 45 s · 30 s · 15 s · now", stacked mode for user/system and power components); `HistoryChart` (range axis, scrub `RuleMark` + drag gesture, event markers). Snapshots.
- [ ] **T7 Composition components.** `StackedBar` (memory composition, disk used/purgeable), `CoreGrid`, `PressureScale` (Warning ≥ 60 %, Critical ≥ 80 %), `ThermalPressureSteps`. Snapshots vs Memory/CPU/Thermals artboards.
- [ ] **T8 DataTable.** Column spec, sort toggle, selection, zebra rows, expandable rows (Apps → processes), context menu hook, `LazyVStack`. Suite `DataTableTests` (sort order, expand state) + snapshot vs Processes artboard row styling.
- [ ] **T9 Feedback components.** `AlertBanner` (vs MenuBarAlert), `ConfirmSheet` (vs Processes force-quit dialog), `Toast`.
- [ ] **T10 StatusGlyph.** Geometry from `StatusIcon.dc.html` SVG (5 arcs r = 6.4 in 18-pt box, center dot r = 1.4, stroke 2.2); per-arc tint; template when calm; `StatusGlyphRenderer` cache. Suite `StatusGlyphTests` (template flag, cache hits) + snapshot vs StatusIcon reference.
- [ ] **T11 TreemapView.** Labels hide below min size; `.other` styled muted; selection callback.

**Verification:** `scripts/test.sh MonitorUIKitTests`; `swift run telltale-render --gallery --out .build/renders/gallery.png` reviewed against references; perf: `SparklinePerfTests` renders 7 sparklines × 60 pts 100× via ImageRenderer, report ms/frame (advisory target < 4 ms).

---

## W4 — App shell: status item, popover panel, dashboard window, navigation, settings

**Goal:** the AppKit shell and dashboard chrome (sidebar, device header, page header with range/pause/settings), settings, launch at login, process actions, visibility → sampling mode.
**Owns:** `project.yml`, `App/**`, `scripts/{run,install}.sh`, `MonitorScreens/Shell/**`, shell snapshot tests.
**Consumes:** `TelltaleRuntime`, `LiveModel`, `NavigationModel`, UIKit components, `AppCommands`/`ProcessActions` types. **Produces:** live `AppCommands`, `ProcessActions`, `UIVisibility` stream, `SettingsStore` (units, popover layout, disabled sensors) injected into env.
**Depends on:** W0. Uses W3 components as they land.

- [ ] **T1 Composition.** `AppEnvironment`: args/env (`--mock`, `--open-dashboard <page>`, `--open-popover`, `TELLTALE_DATA_DIR`, `TELLTALE_DISABLE_SENSORS`), `SettingsStore` (UserDefaults suite scoped to data dir), runtime creation, env injection helper `func install<V: View>(_ v: V) -> some View`. Accept: `scripts/run.sh --mock calm` launches; `log stream --predicate 'subsystem == "dev.telltale"' | head` shows mode.
- [ ] **T2 StatusItemController.** Glyph from `live.alert` (observation re-armed), template/tinted swap, one pulse on `pulseToken` change, click toggles popover, right-click menu (Open Dashboard, Pause/Resume, Settings…, Quit). Accept: `--mock thermalFair` ⇒ amber thermals arc; `--mock thermalCritical` ⇒ red + one pulse; screenshot via `screencapture -R` of menu bar region reviewed vs StatusIcon reference.
- [ ] **T3 PopoverPanelController.** Borderless non-activating `NSPanel`, 360 pt wide, positioned under the status item on the screen that owns it; closes on outside click/Esc/status click; hosting view created on open and released on close; reports `popoverOpen`. Accept: open/close 20× ⇒ RSS back within 3 MB (`ps -o rss=`).
- [ ] **T4 DashboardWindowController + VisibilityTracker.** Window per ARCHITECTURE §5.12; released on close; occlusion/miniaturize/page/inspected app ⇒ `runtime.setVisibility`. Accept: log shows interactive ↔ background when window hidden behind another fullscreen app / minimized / closed.
- [ ] **T5 Shell views.** `DashboardRoot` layout (custom sidebar, no `NavigationSplitView`), `Sidebar` (Monitor/System/Activity sections, live values per item), `DeviceHeader` ("MacBook Pro 14″ · M4 Pro · 8P + 4E CPU · 16-core GPU · 24 GB unified memory · up 4 d 7 h"), `PageHeader` (title, subtitle, `RangePicker`, Pause, Settings). Accept: `scripts/render.sh overview calm` chrome matches Main reference (checklist in PR); `ShellSnapshotTests`.
- [ ] **T6 AppCommands live.** Open dashboard at page, inspect app, pause/resume (runtime + glyph dim), close popover, quit (flush store via `runtime.shutdown()`).
- [ ] **T7 ProcessActionsLive.** Per ARCHITECTURE §5.12; `canControl` false for root/other users. Accept: `ProcessActionsTests` against a spawned `sleep 100` child (quit ⇒ exits; force ⇒ SIGKILL; root pid 1 ⇒ `canControl == false`).
- [ ] **T8 Settings.** Window + `SettingsView`: launch at login (`SMAppService.mainApp` register/unregister, status text), units, popover rows order (drag) + hide toggles, "Re-enable sensors" (clears canary + disabled list). Accept: toggles persist across relaunch; `scripts/install.sh` then enabling launch at login shows Telltale in System Settings › Login Items.
- [ ] **T9 PowerEvents.** Sleep/wake ⇒ runtime; screen lock not treated as sleep.
- [ ] **T10 App Nap decision hook** (after W7 T5 measurement): add activity assertion only if W7 reports median background interval > 6 s.

**Verification:** `scripts/build.sh && scripts/run.sh --mock calm`; manual: icon, popover, dashboard navigation over all 10 pages, settings; `scripts/test.sh ShellSnapshotTests ProcessActionsTests`. Perf: mock mode, UI closed, 5 min: report `%CPU`/RSS (`scripts/perf.sh 5 --mock`).

---

## W5a — Screens A: popover, Overview, CPU, GPU, Memory, Network

**Goal:** pixel-faithful (structure/tokens/copy) implementations of MenuBar, MenuBarAlert, Main (Overview), CPU, GPU, Memory, Network artboards, plus spec extras in design style.
**Owns:** see §1.
**Consumes:** `LiveModel` (§5.6), `NavigationModel`, `HistoryProvider` (via env), UIKit components, `AppCommands`, `ProcessActions`, `UnitPreferences`, `PopoverLayout`. **Produces:** screens registered in `ScreenCatalog` (already present).
**Depends on:** W0; W3 phase A for visuals.

Per-page loop (applies to every task): build against `LiveModel.mock(.calm)` → `scripts/render.sh <screen> calm` → compare with `docs/design/reference/<Artboard>.png` (checklist in PR) → also render `sensorsUnavailable` and `collecting` → record goldens (`TELLTALE_RECORD=1 scripts/test.sh <Page>SnapshotTests`) → range picker: `live` uses `LiveModel.series`, others call `historyProvider.series(...)` (MockHistoryProvider in tests).

- [ ] **T1 PopoverRoot.** Header (glyph, "Telltale", status line "All systems nominal" / alert title), `AlertBanner` from `alert.active.first` (copy per MenuBarAlert: "Thermal pressure: Fair", culprit sentence with temperature, buttons "Show Thermals" → `openDashboard(.thermals)`, "Quit <culprit>" → `processActions.quit`), category rows in `PopoverLayout.order` minus hidden (label, subtitle, value, sparkline), row click expands top 3 apps (`LiveModel.topApps`), "Top consumer", footer: Quit (Telltale), Open Dashboard, History. Accept: renders `popover-calm` and `popover-alert` match references; `PopoverTests` (expand shows 3 apps; hidden row absent).
- [ ] **T2 OverviewPage.** Five KPI tiles, "Last 60 seconds" multi-line chart, Power panel, Disk panel, Top processes table (5 rows; columns Process/CPU/GPU/Memory/Network/Energy impact as W) with row actions menu. Accept: vs Main reference.
- [ ] **T3 CPUPage.** Total/User/System/Idle, load avg, threads/processes, P and E `CoreGrid`s with cluster freq/residency/power, usage chart (user/system stacked), Top CPU consumers (PID, User, % CPU, CPU time, Threads) with Quit/Force Quit. Accept: vs CPU reference.
- [ ] **T4 GPUPage.** Utilization, frequency, power, GPU memory, cores; utilization & frequency chart; Neural Engine (watts only — ruling); media engines only if non-empty; GPU clients table (% GPU, GPU time; Renderer and per-app GPU memory columns dropped — ruling). Accept: vs GPU reference minus dropped items.
- [ ] **T5 MemoryPage.** Used/pressure/swap/compressed/page-ins tiles, composition `StackedBar`, pressure chart with thresholds, swap panel, Top memory consumers (Compressed/Private/Ports only if non-nil — ruling). Accept: vs Memory reference.
- [ ] **T6 NetworkPage.** Download/Upload/Today (`historyProvider.total` since local midnight)/Latency/Packet loss tiles, throughput chart, Interfaces panel (Wi-Fi band/channel/RSSI/link rate; no SSID, no Public IP — rulings), Network by app (Download, Upload, This session, Connections). Accept: vs Network reference minus dropped items.

**Verification:** `scripts/test.sh PopoverTests OverviewSnapshotTests CPUSnapshotTests GPUSnapshotTests MemorySnapshotTests NetworkSnapshotTests`; `scripts/run.sh --mock calm` walk-through; perf: dashboard on CPU page, mock 1 s updates, `scripts/perf.sh 2 --mock --interactive` report `%CPU` (advisory ≤ 8 %).

---

## W5b — Screens B: Thermals, Power, Disk, Processes (+ app detail), History

**Goal:** remaining pages + spec features: Apps/Processes toggle, app detail inspector with per-app charts and live connections, row actions, time-travel treemap, events, export CSV, empty/collecting states.
**Owns:** see §1. **Consumes/Produces:** as W5a (+ `HistoryProvider.appShares/appSeries/events/exportCSV/topApps/peak`). **Depends on:** W0; W3 phase A; `DataTable` (W3 T8) and `TreemapView` (W3 T11) for T4/T5 visuals.

- [ ] **T1 ThermalsPage.** SoC average, hottest sensor, pressure, fans (read-only: "automatic" label, no Automatic/Full speed buttons — ruling), `ThermalPressureSteps`, temperatures chart (P-cores/GPU/Battery), sensors table by group (Now, Peak 1 h via `historyProvider.peak`) expandable to raw sensors (demand `.rawTemperatures`). Accept: vs Thermals reference minus fan controls.
- [ ] **T2 PowerPage.** Package + components tiles, battery drain, power-by-component stacked chart, Battery panel (health, condition, cycles, capacity, temperature, adapter), Energy table (Energy impact as W, "12 h average" via `topApps(.energy, 12 h)`, "Preventing sleep"; App Nap column dropped — ruling). Desktop: battery panel → `EmptyState`. Accept: vs Power reference minus App Nap.
- [ ] **T3 DiskPage.** Read/Write (MB/s + IOPS), free space, SSD wear, volumes (used/purgeable bars, Eject for ejectable → `processActions.eject`), throughput chart, SSD health (SMART or status-only), disk activity by process. Accept: vs Disk reference.
- [ ] **T4 ProcessesPage + ProcessTableModel + AppInspector.** Search, sort chips (CPU/GPU/Memory/Network/Disk/Energy), Apps/Processes toggle (apps expand to processes), counts line, table columns per artboard; inspector: header (icon, name, path, PID, user, threads), metric tiles, per-app charts (`LiveModel.appSeries` live; `historyProvider.appSeries` for ranges), process list, live connections (demand `.connections`; remote host, port, protocol, rate), actions Quit / Force Quit… (`ConfirmSheet` copy from artboard) / Reveal in Finder / Open in Activity Monitor, disabled when `!canControl`; toast after quit. `ProcessTableModel` sorts/filters once per frame. Accept: vs Processes reference; `ProcessTableModelTests` (sort, filter, group expand, selection survives refresh); `ProcessesTests` using `ActionLog`.
- [ ] **T5 HistoryPage + HistoryModel + TimeTravelTreemap.** Ranges 1H/24H/7D/30D, lanes (CPU, GPU, Memory pressure, Network ↓, SoC temperature, Package power) as `HistoryChart`s sharing one scrub, event markers + jump list, "At <time>" readout with top process and note, time-travel treemap (`appShares(at: scrub ?? now)`; live when scrub nil), Export CSV (`NSSavePanel` → `exportCSV`), collecting/empty overlays from `coverage()`. Accept: vs History reference; `HistoryModelTests` (scrub → queries debounced ≤ 10/s; range change cancels in-flight tasks).

**Verification:** `scripts/test.sh ThermalsSnapshotTests PowerSnapshotTests DiskSnapshotTests ProcessesTests ProcessTableModelTests HistoryModelTests`; mock walk-through; perf: Processes page with 600 mock processes at 1 s, report `%CPU` and main-thread hitch (`os_signpost` around `apply`+render; advisory ≤ 16 ms/frame).

---

## W6 — Sensor adapters (4 streams; start each when its findings exist)

Common recipe per sensor (each W6 stream repeats it for every sensor it owns):
1. Read the findings doc(s). Port the matching spike (`Spikes/Sources/spike-*/main.swift`) into the stub file; sync the header from `Spikes/Sources/CPrivate/include/` into `MonitorCore/Sources/CPrivate/include/` (you own it).
2. Split **parse** (pure: CF dictionary/plist/struct → Reading) from **FFI** (handles, calls). Capture raw dumps once (`telltale-probe --sensor <id> --dump <file>` or the spike) into `Tests/MonitorSensorsTests/Fixtures/`; TDD the parse layer (`<Name>ParseTests`).
3. FFI smoke test gated by `TELLTALE_HW_TESTS=1` (`<Name>SmokeTests`): prepare + 2 samples, plausible ranges.
4. Compare `scripts/probe.sh --sensor <id> --ticks 5 --interval 1` against the reference tool named below (tolerance from findings; default ±30 %).
5. Cost: `scripts/probe.sh --sensor <id> --bench --ticks 30` p50/p95 within ARCHITECTURE §7 estimate or findings number; paste into PR.
6. Errors: every failure path maps to `SensorError` (never crash, never block > 250 ms).

Test command pattern: `scripts/test.sh <Name>ParseTests` and `TELLTALE_HW_TESTS=1 scripts/test.sh <Name>SmokeTests`.

### W6a — Process & host
**Findings:** `docs/findings/procs.md`, `sysmon.md`, `extras.md` (§ sleep assertions). **Depends on:** W0.
- [ ] **T1 RusageProcessSensor** (spike-procs): retained pid buffer, `proc_pid_rusage` V4, mach ticks → ns, name/path/responsible cached per `ProcessID`, EPERM ⇒ `restricted`. Ref: Activity Monitor CPU/Memory. Bench target ≤ 8 ms @ 600 pids.
- [ ] **T2 SysmonProcessSensor** (spike-sysmon): attribute IDs from findings, async reply ≤ 250 ms (continuation + timeout), root processes visible. If findings say ❌: class stays `unavailable` with the reason.
- [ ] **T3 FallbackProcessSensor**: sysmon primary, rusage fallback; per-pid merge (sysmon fields preferred); `source` reported.
- [ ] **T4 HostCPUSensor**: `host_processor_info` (dealloc each tick), core kinds from `hw.perflevel*` + IORegistry cluster mapping (findings), load avg. Ref: `top -l 2 -n 0 | grep "CPU usage"`.
- [ ] **T5 MemorySensor**: `host_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level`, pressure fraction per findings. Ref: `vm_stat`, `sysctl vm.swapusage`, Activity Monitor Memory.
- [ ] **T6 DeviceInfoSensor**: model name (IORegistry `product-name`), chip (`machdep.cpu.brand_string`), P/E counts, GPU cores (AGX `gpu-core-count`), memory, boot time, battery presence, fan count.
- [ ] **T7 SleepAssertionSensor**: `IOPMCopyAssertionsByProcess`. Ref: `pmset -g assertions`.
**Verification:** CP2 (live CPU/memory/processes vs Activity Monitor).

### W6b — SoC, thermal, power
**Findings:** `ioreport.md`, `gpu-apps.md`, `temps.md`, `smc.md`. **Depends on:** W0.
- [ ] **T1 IOReportSensor**: subscription once; energy channels → W over interval; cluster residency (+ MHz if findings provide table); GPU active/freq; media engines only if exposed. Ref: `sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -n 1` (run by the user if sudo needed).
- [ ] **T2 GPUClientsSensor**: AGX user clients → per-pid accumulated GPU ns (sum per pid), device utilization, in-use system memory. Ref: Activity Monitor % GPU.
- [ ] **T3 HIDTemperatureSensor + TemperatureCatalog**: client created once, services cached, name → `TemperatureGroup` table from findings, garbage filter. Ref: spike-temps under `yes` load.
- [ ] **T4 SMCSensor**: `smc.c` port, key list cached in `prepare()`, fans (rpm/min/max), selected T-keys, system power key if found. Ref: spike-smc.
- [ ] **T5 ThermalStateSensor**: `ProcessInfo.thermalState` (+ IOKit thermal pressure level if findings recommend finer levels mapped to 4 steps).
- [ ] **T6 BatterySensor**: `AppleSmartBattery` registry props + `IOPSCopyPowerSourcesInfo` + `ProcessInfo.isLowPowerModeEnabled`. Ref: `ioreg -rn AppleSmartBattery | grep -E 'Cycle|Capacity|Temperature'`, `pmset -g batt`.
**Verification:** CP4 (GPU/Thermals/Power pages live).

### W6c — Network
**Findings:** `nstat.md`, `extras.md` (§ ping, Wi-Fi). **Depends on:** W0.
- [ ] **T1 NStatSensor**: long-lived manager on own queue; added/removed sources; pid/epid from description; counts query per tick; closed-flow bytes accumulated into `closedBytesByPID`; endpoints only with `.connections`; lock-protected state (`OSAllocatedUnfairLock`). Ref: `nettop -P -L 2 -J bytes_in,bytes_out -s 2`.
- [ ] **T2 ReverseDNS**: async `getnameinfo` on a serial queue, LRU 512, TTL 10 min, no blocking in `sample()`.
- [ ] **T3 InterfaceSensor**: `getifaddrs` `if_data` counters (64-bit via sysctl `NET_RT_IFLIST2` if needed), kind via SystemConfiguration, primary interface, router IPv4 (`SCDynamicStore State:/Network/Global/IPv4`). Ref: `netstat -ibn`.
- [ ] **T4 WiFiSensor**: CoreWLAN rssi/noise/channel/band/width/tx rate/PHY → "Wi-Fi 6E" label; SSID never read (ruling).
- [ ] **T5 LatencyProbe**: `SOCK_DGRAM` ICMP echo to router every 10 s on own queue, 5-min loss window. Ref: `ping -c 5 <router>`.
**Verification:** CP4 (Network page + app inspector connections live).

### W6d — Disk
**Findings:** `extras.md` (§ disk stats, SMART). **Depends on:** W0.
- [ ] **T1 DiskIOSensor**: `IOBlockStorageDriver` `Statistics`, BSD name via parent media, internal flag. Ref: `iostat -d -w 1 -c 3`.
- [ ] **T2 VolumeSensor**: `FileManager.mountedVolumeURLs` + `URLResourceValues` (capacity, available, important, internal, ejectable, encrypted, fs type). Ref: `df -h`, Finder Get Info.
- [ ] **T3 SMARTSensor**: NVMe SMART plugin per findings; else `SMARTStatus` only from IORegistry. Cadence 300 s, only with `.smart`.
**Verification:** CP4 (Disk page live).

---

## W7 — Integration, probe, fixtures, perf

**Goal:** live pipeline, tooling that other streams use for verification, recorded fixtures, perf measurement, running the checkpoints.
**Owns:** see §1. **Consumes:** everything. **Produces:** `TelltaleRuntime` live mode, `telltale-probe`, `scripts/perf.sh`, `docs/perf/*.md`, recorded fixtures.
**Depends on:** W0; T1 needs W1 T12–T13.

- [ ] **T1 LivePipeline.** `TelltaleRuntime.make(.live)`: `SamplingEngine(factory: .live, disabled:)`, `HistoryStore(.file(dataDir/history.sqlite))` (in-memory fallback), consumer tasks (frames → `LiveModel`, records → store), maintenance timer, visibility → engine + `live.isPresenting`, pause, sleep/wake, `shutdown()` flushSync. Accept: `RuntimeTests` with `SensorFactory` of `FixtureSensor`s + in-memory store: 10 ticks ⇒ 10 system rows, LiveModel phase `.live`, pause ⇒ no rows.
- [ ] **T2 telltale-probe.** `--list`, `--sensor <id>`, `--ticks`, `--interval`, `--bench` (p50/p95/max per sensor + total), `--dump <file>` (raw reading JSON), `--record <file>` (`[RawTick]`), `--frames` (one-line summary per frame: cpu %, mem, top 3 apps, alert), `--maintain-now [--data-dir <dir>]` (runs store rollup + retention once, for CP3). Accept: runs with any subset of real sensors; unavailable ones listed with reasons.
- [ ] **T3 Fixtures.** Record into `Tests/MonitorEngineTests/Fixtures/recorded/`: `idle` (20 ticks @1 s), `load-8core` (`yes` ×8), `chrome` (Chrome with 10 tabs), `sleep-wake` (ticks around `pmset sleepnow`, user-run). Keep each < 2 MB (strip `processes` to top 200 if needed). Accept: W1 T14 passes.
- [ ] **T4 perf.sh.** Launch live app (UI closed), 60 s warm-up, sample `ps -o %cpu=,rss= -p <pid>` every 5 s for N min; also `--interactive` (launches with `--open-dashboard processes`, parsed by W4 T1), `--mock`. Output: avg/p95 CPU %, max RSS, DB size delta. Writes `docs/perf/<date>-<cp>.md`.
- [ ] **T5 App Nap / interval check.** Log actual `frame.interval` in background for 10 min; report median/p95; hand decision to W4 T10.
- [ ] **T6 Unavailable drills.** `TELLTALE_DISABLE_SENSORS=soc,smc,networkFlows,temperatures scripts/run.sh` ⇒ every affected value "—" with tooltip, no crashes, alerts calm; crash canary drill (debug arg `--crash-sensor smc` that aborts inside `prepare()` once) ⇒ next launch shows "Disabled after a crash".
- [ ] **T7 Soak.** 8 h live run: RSS drift < 10 MB, DB size within projection, `leaks Telltale | tail -3` = 0 leaks.
- [ ] **T8 Run checkpoints CP2–CP5** (below) and file findings as ICRs/bugs to owning streams.

**Verification:** `scripts/test.sh RuntimeTests`; perf reports in `docs/perf/`.

---

## Integration schedule

Merge order (each arrow = merged to `dev` and rebased by everyone):

1. **W0** → tag `cp0`.
2. **W3 phase A** (T0–T5), **W1 T1–T11**, **W4 T1–T5** — any order, as ready.
3. **W5a / W5b** page by page (each page = one PR), **W3 T6–T11**, **W4 T6–T9**.
4. **W1 T12–T13** → **W7 T1–T2** (live pipeline with stub store).
5. **W2** (all) → W7 flips live runtime to the real store.
6. **W6a** → CP2. Then **W6b / W6c / W6d** independently as findings allow.
7. **W7 T3** fixtures → **W1 T14**.
8. Polish PRs → CP5.

Checkpoints (integrator runs; full `swift test` at each — reason: shared-infrastructure merge point):

| CP | When | Steps | Pass criteria |
|---|---|---|---|
| **CP0** foundation | after W0 | `scripts/ci.sh`; `swift test`; `scripts/run.sh --mock calm`; `scripts/render.sh --all` | builds from CLI; status item visible; popover + dashboard open; 10 pages reachable (placeholders); 18 sensors listed by probe; private frameworks linked |
| **CP1** mock app | W3 A + W1 core + W4 T1–T5 + first W5 pages | `scripts/run.sh --mock calm`, then `--mock thermalFair`, `--mock thermalCritical`, `--mock collecting`, `--mock sensorsUnavailable`; `scripts/render.sh popover-alert thermalFair` vs reference | glyph states match StatusIcon; banner copy matches MenuBarAlert; popover rows expand to top 3; visibility switches 1 s ↔ 5 s in log; "—" + tooltip in unavailable scenario |
| **CP2** live core (≈ M1/M2) | W1 all + W6a + W7 T1–T2 | `scripts/run.sh` (live); compare CPU %, memory, top apps with Activity Monitor for 2 min; `scripts/perf.sh 10` | top-5 apps match AM (±30 %); helpers grouped; restricted processes shown (or sysmon covers them); perf reported (advisory < 1 % CPU, < 80 MB) |
| **CP3** history (≈ M5) | + W2 + W5b T5 + W7 | live 30 min; quit/relaunch; History 1H/24H; `telltale-probe --maintain-now` (forces rollup) then 7D/30D; scrub; Export CSV | data survives relaunch; pause gap visible; treemap changes with scrub; CSV opens in Numbers with expected columns; DB size logged |
| **CP4** all sensors (≈ M3/M4/M6) | + W6b + W6c + W6d | every page live; app inspector connections; actions on a test app (TextEdit): Quit, Force Quit confirm, Reveal, Open in AM; drills (W7 T6); `scripts/perf.sh 10` + `--interactive 2` | no "—" except documented unavailable sources; actions disabled on root processes; perf reported vs CP2 delta |
| **CP5** design sign-off | all pages merged | `scripts/render.sh --all` vs `docs/design/reference/*`; checklist per screen; record goldens; 8 h soak (W7 T7) | every artboard's structure/tokens/copy matched or ruling-justified; goldens committed; soak within limits |

---

## Unresolved questions

1. History artboard copy says "5-minute resolution for 24 h"; SPEC says full resolution 24 h / 1 min 7 d / 15 min 30 d. Plan follows SPEC and changes the copy to match. OK?
2. Runaway-app thresholds: ≥ 150 % CPU sustained 5 min (exit < 80 % for 30 s), elevated only. Acceptable defaults?
3. Grouping: user-owned non-app executables (node, Homebrew services) get their own `.process` group instead of "System" (SPEC says non-app daemons → System). Keep?
4. Processes inspector "Sample" button (artboard) isn't in the rulings: drop it, or run `/usr/bin/sample <pid>` and open the report?
5. Popover row reorder/hide (SPEC) lives in Settings, not drag-in-popover. OK?
6. Paused state glyph: dimmed calm glyph (design doesn't show it). OK?
7. Bundle id prefix `dev.telltale` and install path `~/Applications/Telltale.app` for launch at login. OK?
8. Reference PNG capture: may the lead use the browser tool on the claude.ai canvas link (renders live values), or local headless Chrome only?
9. Sensors needing sudo to verify (powermetrics) — user runs those reference commands manually?
