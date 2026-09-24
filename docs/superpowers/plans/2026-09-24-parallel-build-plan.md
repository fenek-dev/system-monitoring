# Telltale — Parallel Build Plan (M1–M6)

> **For agentic workers:** one workstream per agent, each in its own git worktree. REQUIRED SUB-SKILLS: superpowers:using-git-worktrees, superpowers:test-driven-development (W1, W2, W3 layout/format math, W6 parse layers), superpowers:verification-before-completion. Steps use `- [ ]`.

**Goal:** build Telltale (SPEC.md) with 4–6 agents working concurrently against the locked interfaces in `docs/ARCHITECTURE.md` §5 (revision 2).
**Design:** `docs/design/DESIGN.md` (tokens, components `TT*`, screens), artboards, reference PNGs `docs/design/reference/<Artboard>@2x.png` (design agent).
**Findings:** `docs/findings/{procs,gpu-apps,ioreport,smc}.md` exist; `temps`, `nstat`, `extras`, coalition notes pending/partial. Facts already applied: ARCHITECTURE §10.

---

## 0. Rules for every stream

- **Worktree:** `git worktree add ../telltale-<id> -b ws/<id>-<slug> dev`. Work, commit and test only there. `scripts/run.sh` sets `TELLTALE_DATA_DIR=.build/data` per worktree. Quit other Telltale instances before running yours.
- **Ownership:** edit only files your stream owns (§1). Model/Package change → ICR (`docs/icr/NNN-<id>-<slug>.md`, ARCHITECTURE §9); continue with a local extension.
- **Merging:** small PRs per task group, rebased on `dev`, fast-forward. Gate: `scripts/ci.sh <YourSuites>` (build all + app build + your suites + the `&-` grep). Integrator (lead until W7 starts, then W7) merges.
- **Tests (user rule):** rerun only failing tests + suites whose sources you touched. Full `swift test` only at checkpoints (reason: shared-infrastructure merge) or on request — say which.
- **Output budget:** use the scripts (they `tail`/`grep`); never paste > ~100 lines.
- **Commits:** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Perf is advisory:** report numbers; don't tune unless a checkpoint shows > 2× budget.
- **No sudo** reference checks (ruling). Verify sensors by plausibility (idle vs `yes`/Metal load) and against `top`, `ps`, `vm_stat`, `nettop`, `iostat`, `ioreg`, `pmset`.

---

## 1. Ownership matrix (no file has two owners)

Paths below are under `MonitorCore/` unless they start with `App/`, `scripts/`, `docs/` or `project.yml`.

| Stream | Owns |
|---|---|
| **W0a** package + model (→ integrator) | `Package.swift`, `Sources/MonitorModel/**` (incl. `Sensors/BuiltinSensors.swift` = `UnavailableSensor`, `FixtureSensor`, `CrashingSensor`; `History/EmptyHistoryProvider.swift`), `Tests/MonitorModelTests/**`, `.gitignore`, `scripts/{gen,build,test,ci}.sh`, `Sources/CPrivate/shim.c`, `Sources/*/_Placeholder.swift` (deleted by W0b) |
| **W0b** stubs + app (→ integrator) | `Sources/MonitorSensors/LiveSensorFactory.swift`; first version of every stub file listed under the other streams |
| **W1** engine + live | `Sources/MonitorEngine/**`, `Sources/MonitorLive/**`, `Tests/MonitorEngineTests/**` (except `Fixtures/recorded/**`), `Tests/MonitorLiveTests/**` |
| **W2** store | `Sources/MonitorStore/**`, `Tests/MonitorStoreTests/**` |
| **W3** UI kit | `Sources/MonitorUIKit/**`, `Sources/MonitorSnapshotTesting/**` (test-only target: `assertSnapshot`), `Tests/MonitorUIKitTests/**`, `Sources/telltale-render/**`, `scripts/render.sh` |
| **W4** app shell | `project.yml`, `App/**`, `scripts/{run,install}.sh`, `Sources/MonitorScreens/Shell/**` (incl. `ScreenCatalog.swift`), `Tests/MonitorScreensTests/Support/**` (shared screen-test helpers), `Tests/MonitorScreensTests/Shell*`, `__Snapshots__/shell-*` |
| **Wm** mocks | `Sources/MonitorMocks/**`, `Tests/MonitorMocksTests/**`, `Sources/MonitorRuntime/MockPipeline.swift` |
| **W5a** screens A | `Sources/MonitorScreens/Popover/**`, `Pages/{Overview,CPU,GPU,Memory,Network}Page.swift`, `Tests/MonitorScreensTests/{Popover,Overview,CPU,GPU,Memory,Network}*` + matching `__Snapshots__/*` |
| **W5b** screens B | `Pages/{Thermals,Power,Disk}Page.swift`, `Tests/MonitorScreensTests/{Thermals,Power,Disk}*` + matching snapshots |
| **W5c** screens C | `Pages/Processes/**`, `Pages/History/**`, `Tests/MonitorScreensTests/{Processes,ProcessTableModel,AppInspector,History}*` + matching snapshots |
| **W6a** process & host | `Sources/MonitorSensors/{Process,Host}/**`, `Sources/CPrivate/include/{Responsibility,Coalition}.h`, `Support/W6a+*.swift`, `Tests/MonitorSensorsTests/{ProcessTable,Coalition,RootMemory,HostCPU,Memory,Device,Assertion}*`, `Tests/MonitorSensorsTests/Fixtures/W6a/**` |
| **W6b** SoC, thermal, power | `Sources/MonitorSensors/{SoC,Thermal,Power}/**` (incl. `Resources/*.json`), `Sources/CPrivate/include/{IOReport,HIDPrivate,SMC}.h`, `Sources/CPrivate/smc.c`, `Support/W6b+*.swift`, `Tests/MonitorSensorsTests/{IOReport,PState,GPUClients,SMC,TemperatureCatalog,HID,Thermal,Battery}*`, `Tests/MonitorSensorsTests/Fixtures/W6b/**` |
| **W6c** network | `Sources/MonitorSensors/Network/**`, `Sources/CPrivate/include/NStat.h`, `Support/W6c+*.swift`, `Tests/MonitorSensorsTests/{NStat,ReverseDNS,Interface,WiFi,Latency}*`, `Tests/MonitorSensorsTests/Fixtures/W6c/**` |
| **W6d** disk | `Sources/MonitorSensors/Disk/**`, `Support/W6d+*.swift`, `Tests/MonitorSensorsTests/{DiskIO,Volume,SMART}*`, `Tests/MonitorSensorsTests/Fixtures/W6d/**` |
| **W7** integration & perf | `Sources/MonitorRuntime/{TelltaleRuntime,LivePipeline}.swift`, `Sources/telltale-probe/**`, `Tests/MonitorRuntimeTests/**`, `Tests/MonitorEngineTests/Fixtures/recorded/**`, `scripts/{probe,perf}.sh`, `docs/perf/**` |

W0b creates the first version of every stub file; ownership transfers to the listed stream when W0b merges. `docs/design/**` belongs to the design agent (not a stream here).

---

## 2. Dependency graph and slots

```
W0a (Package, scripts, MonitorModel) ──┬── W1 engine+live ──(T1 LiveModel day 1)──┐
                                       ├── W2 store ─────────────────────────┐    │
                                       ├── W6a/b/c/d (as findings allow) ────┼────┤
                                       └── W0b (all stubs, minimal app) ─┬── W3 UI kit ── phase A ──┐
                                                                         ├── W4 shell ──────────────┤
                                                                         ├── Wm mocks ──────────────┤
                                                                         ├── W7 T2 probe            │
                                                                         └── W5a / W5b / W5c ◀──────┘
                                                              all ──▶ W7 live pipeline, fixtures, perf, checkpoints
```

| Stream | Hard deps (merged first) | Soft |
|---|---|---|
| W1, W2 | W0a | — (W1/W2 own their stubs; they create them if W0b hasn't landed) |
| W6a/b/c/d | W0a + its findings | W0b's `LiveSensorFactory` (until then the sensor is tested via smoke/parse tests), W7 T2 probe |
| W3, W4, Wm, W7 T2 | W0b | Wm T4 needs W1 T1 |
| W5a | W0b | W1 T1 (LiveModel), W3 phase A, **W3 T10 (`TTCoreBars`) for CPU page**, W3 T11 (`TTPopoverRow`), W4 T1 (ScreenCatalog), Wm T1 (scenarios incl. real `.calm`) |
| W5b | W0b | as W5a + W3 T10 (`TTFanGauge`) |
| W5c | W0b | as W5a + W3 T6 (`TTTable`), T8–T9 (treemap), Wm T2 |
| W7 T1 live pipeline | W1 T14–T15 | W2 (stub store until merged) |

Slot plan (6 agents; a slot moves to its next item when done):

| Slot | Day 0 | After W0a / W0b | Then | Then |
|---|---|---|---|---|
| 1 | W0a (lead) → W0b | W1 (T1 first, merge day 1) | W7 (T1, T3–T8) | CP runs |
| 2 | — | W2 (after W0a) | W7 T2 probe | W6d → W6c |
| 3 | — | W6a (after W0a; findings exist; verifies with spikes until the probe lands) | W6b | — |
| 4 | — | W4 (after W0b) | W5c | — |
| 5 | — | Wm (after W0b; ~½ day) | W5a | W5b |
| 6 | — | W3 (after W0b) | CP5 polish | — |

W0a ≈ 2–3 h, W0b ≈ 3–4 h, both by the lead. W1, W2 and W6a start as soon as W0a merges.

---

## W0a — Package, scripts, MonitorModel (lands first; unblocks W1, W2, W6)

**Goal:** `swift build` compiles; MonitorModel is complete and real. **Owns:** §1. **Depends on:** nothing.

- [ ] **T0a.1 Scripts + ignore.** `scripts/{gen,build,test,ci}.sh` per ARCHITECTURE §1 (`ci.sh` includes the `&-` grep; `build.sh` no-ops with a message until `project.yml` exists). `.gitignore` += `Telltale.xcodeproj/`, `.build*/`, `MonitorCore/.build/`.
  Accept: `bash -n scripts/*.sh`.
- [ ] **T0a.2 Package.** Every target, product (incl. `MonitorModel`, `MonitorLive` for the app), test target and resource of ARCHITECTURE §2 (incl. `MonitorLive`, `MonitorSnapshotTesting`, all test targets; resources `SoC/Resources`, `Thermal/Resources` with `{}` JSON). Every non-Model target gets one `_Placeholder.swift` so it compiles. `CPrivate`: `shim.c` + copies of `Spikes/Sources/CPrivate/include/{Responsibility,IOReport,HIDPrivate,SMC,NStat}.h` and `smc.c` (no `Sysmon.h`); weak linker flags; `linkedFramework` IOKit/CoreWLAN/SystemConfiguration on `MonitorSensors`; GRDB `from: "7.0.0"`.
  Accept: `cd MonitorCore && swift build 2>&1 | grep -E 'error|Build' | tail -3` → `Build complete`.
- [ ] **T0a.3 MonitorModel (real).** All model types of ARCHITECTURE §5.1–5.5 and 5.8–5.11 with explicit `public init`s, `Codable`/`Hashable` as declared, `MetricKey.ordinals`, `SensorError.fromErrno`, `unavailableReason(…)`, `UIVisibility.demand`, `HistoryRange.displayBucket`, `ProcessID.coalitionResidual`, `BuiltinSensors.swift` (`UnavailableSensor`, `FixtureSensor`, `CrashingSensor`), `SensorSuite.allUnavailable/crashing`, `SensorFactory.crashing`, `RecordBatch`, `EmptyHistoryProvider`, `HistoryProvider` bucket overloads, statics (`.empty`, `.placeholder`, `.calm`, `.noop`).
  Accept (tests limited to): `scripts/test.sh MonitorModelTests` — `MetricVector` by-rawValue round-trip (reordered keys, unknown key, NaN omitted), `RawTick` without the `coalitions` key → `.notRequested`, `SensorResult` round-trip (all four cases), `UIVisibility.demand` table.
- [ ] **T0a.4 Merge** to `dev`, tag `w0a`.

## W0b — Stubs + minimal app (unblocks W3, W4, Wm, W5, W7 T2)

**Goal:** every other public symbol exists as a compiling stub; the app builds from CLI and shows a status item. **Depends on:** W0a.

- [ ] **T0b.1 Stubs.** Delete the `_Placeholder.swift` files; write exactly the signatures of ARCHITECTURE §5.6 (incl. `sampleOnceRaw`), 5.7, 5.9 (`HistoryStore`), 5.10 (`NavigationModel`), 5.11 (runtime façade, `RuntimePipeline`, `LivePipeline`/`MockPipeline`), 5.12 (UIKit placeholder bodies; `SnapshotRenderer` with `Path`; `MonitorSnapshotTesting.assertSnapshot` stub), Screens (`DashboardRoot`, `PopoverRoot`, `SettingsView`, every page, `ScreenCatalog` with empty `entries`), sensors (one class per adapter, `prepare()` throws `.unavailable("not implemented")`, cadence per §5.4) + `LiveSensorFactory`. `MockDataProvider` returns `SystemFrame.empty`-based frames for every scenario (real data = Wm T1). `telltale-render`/`telltale-probe` mains print "not implemented". If W1, W2 or a W6 stream already merged files it owns, keep them (W0b only fills gaps; `LiveSensorFactory` references the class names fixed in ARCHITECTURE §2).
  Accept: `swift build` clean under Swift 6 strict concurrency. No new tests.
- [ ] **T0b.2 Minimal app.** `project.yml`, `App/Info.plist`, `main.swift`, `AppDelegate` with an `NSStatusItem` (SF Symbol placeholder) and Quit.
  Accept: `scripts/build.sh` → `BUILD SUCCEEDED` (proves `unsafeFlags` survive `xcodebuild`; else move flags to `OTHER_LDFLAGS` in `project.yml`); `otool -l <app>/Contents/MacOS/Telltale | grep -A3 LC_LOAD_WEAK_DYLIB` lists IOReport and NetworkStatistics.
- [ ] **T0b.3 CP0.** `swift build` + `scripts/build.sh` + `scripts/run.sh` → status item visible. Merge, tag `cp0`.

---

## W1 — Engine + live model (TDD)

**Goal:** RawTick → SystemFrame (rates, grouping, coalition attribution, energy) → records/events; sampling actor; `LiveModel`.
**Owns:** §1. **Consumes:** MonitorModel. **Produces:** ARCHITECTURE §5.6–5.8 implementations. **Depends on:** W0a (creates its own stubs if W0b hasn't landed).

Each task: failing test → implement → `scripts/test.sh <Suite>`.

- [ ] **T1 MonitorLive (merge first, day 1).** `RingBuffer`, `LiveHistory` (time windows, gap points), `LiveModel`: phases, `isPresenting` gate, change-only assignment, per-category version counters, `@ObservationIgnored` ring buffers, cached `topApps`/`topConsumer`, per-app series for top 64. Suite `LiveModelTests` (uses `withObservationTracking`: a memory-only change does not fire a CPU observer; equal frame fires nothing).
- [ ] **T2 RateCalculator.** capturedNs semantics: same capturedNs → previous result; first sight nil; decrease → nil + rebaseline; prune; reset. Suite `RateCalculatorTests`.
- [ ] **T3 CPUTicks.** Suite `CPUTicksTests`.
- [ ] **T4 AppResolver + AppGrouper.** ARCHITECTURE §5.1 rules 1–6 (fake `.app` bundles in a temp dir; user non-bundle → `.process`; restricted → by responsible PID if known else `.system`; AGX exited creator → `.system`); cache hit doesn't touch disk. Suite `AppGroupingTests`.
- [ ] **T5 ProcessAssembler.** sysctl list + rusage v6 (cpu %, energy nJ, disk, footprint), AGX per-client deltas summed per pid (client reset/recreate guarded), NStat per `ProcessID` (flows + cumulative `closedBytes`; `ProcessID(pid, 0)` matches the live pid, else → `.system`; `unattributedBytes` → `.system`), `rootMemory` RSS for restricted pids (`memorySource = .rss(age)`), assertions; PID reuse. Suite `ProcessAssemblerTests`.
- [ ] **T6 CoalitionAttributor.** Runs **only for coalitions with ≥ 1 `.restricted` member**; CPU and disk residual, clamp ≥ 0, single restricted member fill (`.coalition`), else synthetic row (leader `p_comm`, leader's app, or "System"), thresholds; no GPU (AGX only; restricted GPU "—" if AGX unavailable). Suite `CoalitionAttributorTests` incl. **no-double-count property test** (200 random coalitions; for coalitions with a restricted member: Σ member CPU/disk incl. filled + synthetic rows == Δcoalition ± 1e-9; all-visible coalitions: rows unchanged, no synthetic rows even when coalition CPU differs from Σ rusage by 1 %).
- [ ] **T7 EnergyAttributor.** Order (ARCHITECTURE §5.6): (1) v6 measured; (2) coalition energy residual for restricted members of coalitions with a restricted member, **skipped when v6 is unavailable**; (3) SoC share only for pids still nil + `usesSoCShareFallback`. Cases: all-visible own app keeps its v6 watts even when coalition energy is lower (2.6 vs 3.3 W); fallback mode never double counts (Σ watts ≤ IOReport CPU+GPU W); `energyEstimated` propagation to `AppSample`. Suite `EnergyAttributorTests`.
- [ ] **T8 SessionAccumulator.** Per-AppKey CPU/GPU time and net bytes since launch; survives process exit; app key change. Suite `SessionAccumulatorTests`.
- [ ] **T9 SystemAssembler.** CPU (host ticks + IOReport clusters incl. watts), GPU (IOReport, AGX fallback), memory, network, thermals (groups from SMC catalog temps; raw list HID+SMC only with `.rawTemperatures`; `approximateMapping`), power (package, PSTR/PDTR), disk; `SystemMetrics`. Suite `SystemAssemblerTests`.
- [ ] **T10 FrameAssembler.** Composition; `sensorHealth`; connections only for `inspectedApp`; `reset()`. Suite `FrameAssemblerTests`.
- [ ] **T11 RecordBuilder.** Suite `RecordBuilderTests`.
- [ ] **T12 AlertEngine.** Table of ARCHITECTURE §5.8 (runaway ≥ 100 % for 5 min; exit < 80 % for 30 s; hysteresis; pulseToken; nil inputs; paused). Suite `AlertEngineTests`.
- [ ] **T13 EventDetector.** Suite `EventDetectorTests`.
- [ ] **T14 SensorSlot + CrashCanary.** Cadence by mode/demand (incl. `.processTable`/`.memoryAlert` for rootMemory), `.fresh`/`.cached` with capturedNs, stale → nil, backoff, unavailable retry (injected clock), canary. Suite `SensorSlotTests`.
- [ ] **T15 SamplingEngine.** Custom executor; `sampleOnce()` and `sampleOnceRaw()` (tick + frame, used by telltale-probe); loop with 20 ms test intervals; **wake-up via sleeper cancel** (setVisibility to interactive samples within 5 ms; paused takes no samples); engine adds `.memoryAlert` while memory arc ≥ elevated; `SampleContext.alertLevel`; wake resets baselines; streams. Suite `SamplingEngineTests`.
- [ ] **T16 Recorded-fixture replay** (after W7 T3). Invariants: usage ∈ [0,1]; Σ app CPU ≈ system CPU × cores × 100 (±15 %) with restricted pids covered by coalition rows; helpers grouped; no spike after wake. Suite `RecordedFixtureTests`.

**Verification:** `scripts/test.sh MonitorLiveTests MonitorEngineTests`. Perf: `FrameAssemblerTests/assemble920` (920 pids, 330 restricted, 770 coalitions) mean of 100 runs; report ms (advisory ≤ 3 ms).

---

## W2 — Store (TDD)

**Goal:** `HistoryStore` per ARCHITECTURE §5.9. **Owns:** §1. **Depends on:** W0a.

All tests `.inMemory` (+ `.file(tmp)` where WAL matters), injected `now`.

- [ ] **T1 Open + migrate.** Pragmas; migrator `v1`; columns from `HistoryMetric`/`AppMetric`; **ALTER TABLE ADD COLUMN for missing metric columns at every open**. Suite `SchemaTests` (add a fake metric name list → column appears; reopen idempotent).
- [ ] **T2 Append + flush.** Buffer, flush on interval/count, one transaction, app upsert, `.other`, events insert/update. Suite `WriterTests`.
- [ ] **T3 Series.** `bucket` default `range.displayBucket`, AVG, gap points for empty buckets, NaN → nil. Suite `SeriesQueryTests`.
- [ ] **T4 Rollups.** Completed buckets only, idempotent, `n`, absent apps = 0. Suite `RollupTests`.
- [ ] **T5 Retention.** 24 h raw / 7 d 1 m / 30 d 15 m / 30 d events; incremental vacuum. Suite `RetentionTests`.
- [ ] **T6 Range routing.** Suite `RangeRoutingTests`.
- [ ] **T7 App queries.** `appSeries`, `appShares(at:)` (fractions sum to 1 incl. `.other`), `topApps`, `total`, `peak`. Suite `AppQueryTests`.
- [ ] **T8 Events + coverage.** Suite `EventQueryTests`.
- [ ] **T9 CSV export.** Golden `Tests/MonitorStoreTests/Golden/export-hour.csv`, streaming. Suite `CSVExportTests`.
- [ ] **T10 Robustness.** No `flushSync` (termination awaits `flush()`); `flush()` completes < 3 s with 120 buffered records; newer `user_version` → file moved aside; unreadable path throws. Suite `RobustnessTests`.
- [ ] **T11 Perf (advisory, on request).** 24 h synthetic at 1 s + maintenance: flush per 30 records, maintenance pass, file size, `series(.month)`/`appShares` latency. Suite `StorePerfTests`.

**Verification:** `scripts/test.sh MonitorStoreTests`; T11 numbers in PR (targets: flush < 5 ms, queries < 50 ms, 30-day projection < 200 MB).

---

## W3 — UI kit

**Goal:** DESIGN.md §1–§2 as the `TT*` components of ARCHITECTURE §5.12; snapshot tooling; render CLI.
**Owns:** §1. **Depends on:** W0b. **Phase A (T1–T6) unblocks W5 — merge each as done.**

- [ ] **T1 Tokens** (DESIGN §1). Suite `TokenTests` (primary/secondary text contrast ≥ 4.5 : 1 on surfaces).
- [ ] **T2 TTFormat** (DESIGN §5, TDD): every sample in the artboards ("212.4%", "3.82 GB", "894 MB", "8.1 MB/s", "12 KB/s", "5 h 40 m", "2:41:07", "4.12 GHz", "1,180 MHz", "3,104", "−52 dBm", "7.15 W", "—"). Suite `TTFormatTests`.
- [ ] **T3 Snapshot harness + telltale-render.** `SnapshotRenderer` (both paths, `Path` enum) in MonitorUIKit; `assertSnapshot` (tolerance, `TELLTALE_RECORD=1`, failure artifacts) in the test-only `MonitorSnapshotTesting` target (imports Testing; depended on only by `MonitorUIKitTests`/`MonitorScreensTests`; check `otool -L` of the app shows no Testing), `telltale-render --screen/--scenario/--all/--gallery/--compare <ref.png>` (side-by-side + 50 % overlay), `scripts/render.sh`. Screens appear once W4 T1 fills `ScreenCatalog`. Suite `SnapshotHarnessTests`.
- [ ] **T4 Core components.** `MetricValue` (unified signature: nil → "—" + tooltip; `estimated` style), `TTCard`, `TTCardHeader`, `TTStatStrip`, `TTMetricTile`, `TTAreaChart` (Canvas, gap rule), `TTSegmented` (+compact), `TTAppTile`, `TTBadge`, `TTProgressBar`, `TTKeyValueList`, `TTEmptyState`, `PageScroll`. Snapshots `ComponentSnapshotTests` after visual check vs Main/CPU references.
- [ ] **T5 Charts.** `ChartSegments` (TDD, `ChartSegmentsTests`), `TTLineChart`, `TTStackedArea`, `TTMirroredChart`, `TTDualChart`, `TTTimelineRow`, `TTLegend`, `TTTimeAxis`. Snapshots.
- [ ] **T6 Table family.** `TTTable` (sort, selection, zebra, `children` expansion, row menu), `TTRowActionsMenu` (env `processActions`, disabled when `!canControl`), `TTSearchField`. Suite `TTTableTests` + snapshot vs Processes reference.
- [ ] **T7 Status glyph.** `TTStatusGlyph` geometry from `StatusIcon.dc.html` (5 arcs r 6.4 in 18-pt box, center r 1.4, stroke 2.2), per-arc tint, template when calm, dimmed when paused; `StatusGlyphRenderer` cache. Suite `StatusGlyphTests` + snapshot vs StatusIcon reference.
- [ ] **T8 TreemapLayout (TDD).** DESIGN §2.28: sorted desc, `other` last (bottom-right), areas ∝ values (±0.5 %), no overlaps, union == rect, results in input order, zeros → `.zero`; aspect ratio ≤ slice-and-dice on 200 random seeds. Suite `TreemapLayoutTests`.
- [ ] **T9 TTTreemap** (gutter, labels, fill, 0.25 s transition unless scrubbing).
- [ ] **T10** `TTCoreBars`, `TTFanGauge`.
- [ ] **T11** `TTPopoverRow` (full/compact/expansion), `TTSidebarItem`.
- [ ] **T12** `TTAlertBanner`, `TTConfirmDialog`, `TTToast`.

**Verification:** `scripts/test.sh MonitorUIKitTests`; `swift run telltale-render --gallery --out .build/renders/gallery.png` reviewed vs references. Perf: `AreaChartPerfTests` (7 charts × 60 pts, 100 renders) ms/frame (advisory < 4 ms).

---

## W4 — App shell

**Goal:** AppKit shell, dashboard chrome, settings, launch at login, actions, visibility → sampling, catalog of screens for rendering.
**Owns:** §1 (incl. the shared `Tests/MonitorScreensTests/Support/` helpers: scenario → `LiveModel`, env setup, snapshot sizes). **Depends on:** W0b; uses W1 T1, W3 components, Wm scenarios as they land.

- [ ] **T1 ScreenCatalog + composition.** `ScreenCatalog` (screen × scenario × size, incl. `LiveModel.mock(_:ticks:)`), `AppEnvironment` (args/env: `--mock`, `--open-dashboard`, `--open-popover`, `--crash-sensor` (DEBUG), `TELLTALE_DATA_DIR`, `TELLTALE_DISABLE_SENSORS`), `SettingsStore` (defaults suite per data dir), environment injection helper. Accept: `scripts/render.sh overview calm` produces a PNG; `scripts/run.sh --mock calm` launches.
- [ ] **T2 StatusItemController.** Glyph from `live.alert`, template/tinted, dim when paused, one pulse per `pulseToken`, click toggles popover, right-click menu (Open Dashboard, Pause/Resume, Settings…, Quit). Accept: `--mock thermalFair` amber thermals arc; `--mock thermalCritical` red + one pulse; `screencapture -R` of the bar vs StatusIcon reference.
- [ ] **T3 PopoverPanelController.** Borderless non-activating `NSPanel`, 360 pt, under the status item; outside click/Esc/status click closes; hosting view created/released per open. Accept: 20 open/close cycles → RSS within 3 MB of start.
- [ ] **T4 DashboardWindowController + VisibilityTracker.** Occlusion/miniaturize/page/inspected app → `runtime.setVisibility`. Accept: log shows interactive ↔ background transitions.
- [ ] **T5 Shell views.** `DashboardRoot` (custom sidebar), `Sidebar` (`TTSidebarItem`, live values), `DeviceHeader`, `PageHeader` (title, subtitle, `TTSegmented` range, Pause, Settings). Accept: overview chrome vs Main reference; `ShellSnapshotTests`.
- [ ] **T6 AppCommands + termination.** Open dashboard at page, inspect app, pause/resume, close popover, quit via `applicationShouldTerminate → .terminateLater → await runtime.shutdown() → reply`. Accept: quit during a 60 s mock run → store flush logged before exit (live mode after CP3).
- [ ] **T7 ProcessActionsLive.** `canControl` false for root/other users and synthetic rows. Suite `ProcessActionsTests` (spawned `sleep 100`: quit exits, force = SIGKILL; pid 1 not controllable).
- [ ] **T8 Settings.** Launch at login, units, popover row order (drag) + hide, re-enable sensors. Accept: persists across relaunch; after `scripts/install.sh`, Telltale listed in Login Items.
- [ ] **T9 PowerEvents.** Sleep/wake → runtime; screen lock ≠ sleep.
- [ ] **T10 App Nap hook** only if W7 T5 reports median background interval > 6 s.

**Verification:** `scripts/build.sh && scripts/run.sh --mock calm`; walk icon/popover/10 pages/settings; `scripts/test.sh ShellSnapshotTests ProcessActionsTests`. Perf: `scripts/perf.sh 5 --mock` (UI closed) report.

---

## Wm — Mocks (small, early)

**Goal:** deterministic scenarios that drive all UI work and snapshots; mock runtime pipeline.
**Owns:** §1. **Depends on:** W0b (T4: W1 T1).

- [ ] **T1 Scenarios (merge first).** All `MockScenario`s with artboard numbers, starting with the real `.calm` (moved from W0: M4 Pro 8P+4E, 24 GB, Xcode 212.4 % 3.82 GB, FCP 96.1 %, Safari, WindowServer, com.docker.backend, Dropbox, Slack, Music, mds_stores; seeded LCG like the artboards), then `thermalFair` (FCP culprit, fans 3,900 rpm), `thermalCritical`, `memoryWarning`/`Critical`, `runaway`, `collecting`, `sensorsUnavailable` (soc, smc, networkFlows unavailable), `paused`, `restricted` (330 restricted rows, `.coalition` fills, synthetic coalition rows, `rss` memory). Suite `MockDataProviderTests` (same seed ⇒ same frames; `thermalFair` ⇒ elevated thermals arc, culprit "Final Cut Pro").
- [ ] **T2 MockHistoryProvider.** 30 days synthetic with History.dc bumps and events; honors `bucket`, gaps (a paused hour), `coverage` short for `collecting`. Suite `MockHistoryProviderTests`.
- [ ] **T3 ActionLog + recording ProcessActions.**
- [ ] **T4 MockPipeline.** Stream → `LiveModel`, 1 s/5 s by visibility, pause. Suite `MockPipelineTests`.

**Verification:** `scripts/test.sh MonitorMocksTests`; `scripts/run.sh --mock restricted` after W4 T1.

---

## W5a / W5b / W5c — Screens

Per-page loop (all three streams): build against `LiveModel.mock(.calm)` → `scripts/render.sh <screen> calm` → compare with `docs/design/reference/<Artboard>@2x.png` (checklist in PR) → render `sensorsUnavailable`, `collecting` (and `restricted` for tables) → record goldens (`TELLTALE_RECORD=1 scripts/test.sh <Page>SnapshotTests`) → range picker: `live` uses `LiveModel.series`, others `historyProvider.series(…, bucket: nil)`. All values via `MetricValue` + `unavailableReason`. Screen layout/copy per DESIGN.md §3.

### W5a — popover, Overview, CPU, GPU, Memory, Network
**Depends on:** W0b; soft: W1 T1, W3 A, W3 T10 (`TTCoreBars`, CPU page), W3 T11 (`TTPopoverRow`), W4 T1, Wm T1.
- [ ] **T1 PopoverRoot** (DESIGN §3.1–3.2): header + status line, `TTAlertBanner` from `alert.active.first` ("Show Thermals", "Quit ‹culprit›"), `TTPopoverRow`s in `PopoverLayout` order minus hidden, expansion = top 3 apps, Top consumer, footer Quit Telltale / Open Dashboard / History. Suite `PopoverTests` + snapshots `popover-calm`, `popover-alert`.
- [ ] **T2 OverviewPage** (§3.4). Energy column in W.
- [ ] **T3 CPUPage** (§3.5): clusters (freq "—" when catalog lacks the chip; cluster power from IOReport), core bars, top CPU consumers.
- [ ] **T4 GPUPage** (§3.6): no Renderer / per-app GPU memory; ANE watts only; media engines only if present; GPU MHz "—" if unresolved.
- [ ] **T5 MemoryPage** (§3.7): **no Compressed/Private/Ports columns** (removed); restricted rows show RSS or "—" per ARCHITECTURE §5.5.
- [ ] **T6 NetworkPage** (§3.8): Today via `historyProvider.total` since local midnight; no SSID, no Public IP; "This session" = `netRxSession/netTxSession`.
**Verification:** `scripts/test.sh PopoverTests OverviewSnapshotTests CPUSnapshotTests GPUSnapshotTests MemorySnapshotTests NetworkSnapshotTests`; perf: `scripts/perf.sh 2 --mock --interactive` report.

### W5b — Thermals, Power, Disk
**Depends on:** as W5a (+ W3 T10).
- [ ] **T1 ThermalsPage** (§3.9): groups (SMC catalog), hottest, pressure steps, read-only fans (no Automatic/Full speed buttons), chart, sensor table with Peak 1 h (`historyProvider.peak`) expanding to the raw list (HID + SMC, demand `.rawTemperatures`); caption when `approximateMapping`.
- [ ] **T2 PowerPage** (§3.10): energy table in W with estimated style when `energyEstimated`, 12 h average via `topApps(.energy, 12 h)`, Preventing sleep; no App Nap column; desktop → battery `TTEmptyState`.
- [ ] **T3 DiskPage** (§3.11): volumes with Eject, SSD health (SMART or status-only), disk activity by process.
**Verification:** `scripts/test.sh ThermalsSnapshotTests PowerSnapshotTests DiskSnapshotTests`.

### W5c — Processes (+ app detail), History
**Depends on:** as W5a + W3 T6, T8, T9; Wm T2.
- [ ] **T1 ProcessTableModel.** Sort/filter/search once per frame; Apps/Processes toggle; apps expand to processes (incl. synthetic coalition rows; `hiddenProcessCount` shown as "+N restricted"); selection survives refresh. Suite `ProcessTableModelTests`.
- [ ] **T2 ProcessesPage** (§3.12): table columns per artboard; restricted/coalition rows per ARCHITECTURE §5.5 (tooltips, estimated style); row actions via `TTRowActionsMenu`; **no Sample button**; toast after quit. Snapshots `processes-calm`, `processes-restricted`.
- [ ] **T3 AppInspector:** header, tiles, per-app charts (`LiveModel.appSeries` live; `historyProvider.appSeries` ranges), process list, live connections (sets `inspectedApp`), actions + `TTConfirmDialog` force quit. Suite `AppInspectorTests` (uses `ActionLog`).
- [ ] **T4 HistoryPage + HistoryModel + TimeTravelTreemap** (§3.13): ranges 1H/24H/7D/30D, lanes with shared scrub, event markers + jump list, "At ‹time›" readout, treemap (`appShares(at: scrub ?? now)`), Export CSV (`NSSavePanel` → `exportCSV`), partial/empty states; subtitle copy per DESIGN.md (24 h = full resolution, ruling). Suite `HistoryModelTests` (scrub queries debounced ≤ 10/s; range change cancels in-flight).
**Verification:** `scripts/test.sh ProcessTableModelTests ProcessesSnapshotTests AppInspectorTests HistoryModelTests`; perf: Processes page with `restricted` scenario (920 rows) at 1 s, `os_signpost` apply+render ms (advisory ≤ 16 ms).

---

## W6 — Sensor adapters (start each when its findings exist)

Recipe per sensor:
1. Read findings; port the spike into the stub file; own/sync the header (add `__attribute__((weak_import))` to private decls and `static inline bool tt_<lib>_available(void)`).
2. Split **parse** (pure: CF/plist/struct/text → Reading) from **FFI**. Capture raw dumps into `Tests/MonitorSensorsTests/Fixtures/<stream>/` (e.g. `Fixtures/W6b/`; via spike or `telltale-probe --dump`); TDD the parser (`<Name>ParseTests`).
3. FFI smoke test gated by `TELLTALE_HW_TESTS=1` (`<Name>SmokeTests`).
4. `scripts/probe.sh --sensor <id> --ticks 5 --interval 1` vs the reference tool below (±30 % unless findings say otherwise).
5. `scripts/probe.sh --sensor <id> --bench --ticks 30` p50/p95 in the PR; compare with ARCHITECTURE §5.4/§7.
6. All failures → `SensorError` (`fromErrno` for errno); never crash; never block > 250 ms.
7. Callback/async sensors: state in a `Sendable` box (`let queue`, `let lock: OSAllocatedUnfairLock<State>`); no `@unchecked`. **Budget ~0.5 day** for Swift 6 `@Sendable` closure/lock work on NStat, `ps`, HID and SMC-sweep callbacks.

### W6a — Process & host
**Findings:** `procs.md` (+ coalition notes). **Depends on:** W0a.
- [ ] **T1 ProcessTableSensor.** `sysctl KERN_PROC_ALL` list per tick (pid, ppid, uid, `p_comm`, `p_starttime`; reused buffer) + `proc_pid_rusage(RUSAGE_INFO_V6)` enrichment (cpu ticks → ns, footprint, disk, `ri_energy_nj`), threads (`PROC_PIDTASKINFO`), `proc_name`/`proc_pidpath` (**record whether root pids return a path**), responsible PID; EPERM → `restricted`. Ref: `ps -Ao pid,user,%cpu,rss,comm`, `top -l 2 -o cpu`. Bench target ≤ 7 ms @ 920 pids.
- [ ] **T2 CoalitionSensor + Coalition.h.** `coalition_info_resource_usage` (weak), `_Static_assert` on the usage struct size + the sentinel-fill prefix check of ARCHITECTURE §6 → `.unavailable` on mismatch; membership via `PROC_PIDCOALITIONINFO` for **new pids only** (exited pids dropped; full pass once at `prepare()`); leader pid; energy field per findings; `gpu_time` [8] stored as `gpuTimeRaw` only (unknown unit, unused). Parse test on a captured struct dump. Ref: plausibility — Σ coalition CPU ≈ `top` total.
- [ ] **T3 RootMemorySensor.** `/bin/ps -axo pid=,rss=` via `Process` on its own queue (~20 ms per run); `sample()` returns last completed result, triggers next when due; parse tests (malformed lines, KB → bytes). Cadence 30 s, `requires: [.processTable, .memoryAlert]`.
- [ ] **T4 HostCPUSensor** (core kinds from `hw.perflevel*` + IOReport channel names). Ref: `top -l 2 -n 0`.
- [ ] **T5 MemorySensor.** Ref: `vm_stat`, `sysctl vm.swapusage`, `memory_pressure`.
- [ ] **T6 DeviceInfoSensor** (`hwModel`, `osBuild`, product name, chip, P/E, GPU cores, memory, boot time, battery, fans).
- [ ] **T7 SleepAssertionSensor.** Ref: `pmset -g assertions`.
- [ ] **T8 GPU energy gap check.** Run `Spikes` `spike-gpu-apps --load` and sample own-pid `ri_energy_nj`; record whether GPU work raises it; if not, file ICR for the `gpuW × gpu share` term.
**Verification:** CP2.

### W6b — SoC, thermal, power
**Findings:** `ioreport.md`, `gpu-apps.md`, `smc.md`, `temps.md` (pending Task 4 fix). **Depends on:** W0a.
- [ ] **T1 IOReportSensor.** Weak-linked; subscription to Energy Model + CPU Complex/Core Performance States + GPU Performance States; watts (`CPU Energy`, `GPU0`/`GPU Energy`, `ANE0`, `DRAM0`, per-cluster `EACC_CPU`/`PACC*_CPU`); residency with idle states `IDLE`/`OFF`/`DOWN`; MHz from `PStateCatalog` (`SoC/Resources/pstates.json`, keyed by hw.model; M1 Max tables from findings; unknown chip → nil); GPU MHz: try `AGXAccelerator` `gpu-perf-states`, else nil. Parse tests with captured channel dicts. Ref: plausibility idle vs 8× `yes` (≥ +4 W CPU, P clusters → 100 %).
- [ ] **T2 GPUClientsSensor.** `clientID` = registry entry ID, `creatorName` from "pid N, Name", Σ `accumulatedGPUTime` per client; device utilization, `In use system memory`. Parse test on creator strings. Ref: `spike-gpu-apps --load` → own pid high %.
- [ ] **T3 SMCDecoder (TDD).** Byte order per key family: fan/temp ints BE, battery `B0**`/`CH**` ints LE, `flt ` LE, `si16`, `sp78`. Suite `SMCParseTests` with findings values (`B0CT` → 1855, `B0DC` → 6075, `CHBV` → 4214, F0Mx 5779).
- [ ] **T4 SMCSensor + TemperatureCatalog.** `prepare()` opens the connection and reads only hard-coded keys (fans `F#Ac/Mn/Mx`, `PSTR`, `PDTR`, catalog T-keys for this hw.model); full key sweep (0.45–0.57 s) on a background queue once, cached in `~/Library/Caches/dev.telltale/smc-keys-<hwModel>-<osBuild>.json`, used for the raw list. Catalog `Thermal/Resources/temperature-catalog.json`: per hw.model prefix → key pattern → `TemperatureGroup`; unknown model → generic families + `approximateMapping`. Suite `TemperatureCatalogTests`. Ref: fans rise under 8× `yes`.
- [ ] **T5 HIDTemperatureSensor.** Raw list only (names carry no P/E/GPU tag → group `.other` unless catalog maps a name); 65–80 ms read; cadence `.every(.seconds(2), background: nil, requires: .rawTemperatures)`.
- [ ] **T6 ThermalStateSensor.**
- [ ] **T7 BatterySensor.** `AppleSmartBattery` ioreg preferred (health = `AppleRawMaxCapacity/DesignCapacity`, cycles, `Temperature` centi-°C, `TimeRemaining`, signed amperage from two's-complement `UInt64`), `IOPSCopyPowerSourcesInfo`, low power mode. Ref: `ioreg -rn AppleSmartBattery`, `pmset -g batt`.
**Verification:** CP4.

### W6c — Network
**Findings:** `nstat.md`, `extras.md`. **Depends on:** W0a.
- [ ] **T1 NStatSensor.** Weak-linked; long-lived manager on the box queue; added/removed sources; pid/epid → `ProcessID` (start time via `sysctl KERN_PROC_PID`, cached; helper in `Support/W6c+StartTime.swift`); `sample()` returns the last **completed** counts query and starts the next (a query costs 21–28 ms on the box queue; cadence: every tick interactive, **10 s background**); removed-flow bytes folded into cumulative `closedBytes[ProcessID]`, pruned 10 min after exit; sources retired before their pid resolves go to cumulative `unattributedBytes` (→ `.system`); a pid whose start time isn't known yet is reported as `ProcessID(pid, 0)`; endpoints only with `.connections`. Ref: `nettop -P -L 2 -J bytes_in,bytes_out -s 2`.
- [ ] **T2 ReverseDNS** (async `getnameinfo`, LRU 512, TTL 10 min).
- [ ] **T3 InterfaceSensor** (64-bit counters, kinds, primary, router). Ref: `netstat -ibn`.
- [ ] **T4 WiFiSensor** (no SSID).
- [ ] **T5 LatencyProbe** (ICMP `SOCK_DGRAM` to router every 10 s, 5-min loss window). Ref: `ping -c 5 <router>`.
**Verification:** CP4.

### W6d — Disk
**Findings:** `extras.md`. **Depends on:** W0a.
- [ ] **T1 DiskIOSensor.** Ref: `iostat -d -w 1 -c 3`.
- [ ] **T2 VolumeSensor.** Ref: `df -h`.
- [ ] **T3 SMARTSensor** (NVMe SMART plugin per findings, else status only; 300 s, `.smart`).
**Verification:** CP4.

---

## W7 — Integration, probe, fixtures, perf

**Owns:** §1. **Depends on:** W0b; T1 needs W1 T14–T15. T2 is done early (slot 2, after W2) so W6 streams can verify.

- [ ] **T2 telltale-probe (early).** Depends directly on MonitorEngine, MonitorSensors and MonitorStore (not Runtime); builds `SensorFactory.live` itself. Single-sensor modes call the sensor directly; `--record`/`--frames` use `SamplingEngine.sampleOnceRaw()`. Flags: `--list`, `--sensor <id>`, `--ticks`, `--interval`, `--demand <opts>`, `--bench` (p50/p95/max + total), `--dump <file>`, `--record <file>` (`[RawTick]`, needs W1 T15), `--frames`, `--maintain-now [--data-dir]`, `--crash-sensor <id>` (uses `SensorFactory.crashing`). Accept: runs with all sensors unavailable (W0b stubs) and lists reasons.
- [ ] **T1 LivePipeline.** Engine + `SensorFactory.live` + `HistoryStore(.file(dataDir/history.sqlite))` (in-memory fallback) + consumers + maintenance timer + visibility + pause + sleep/wake + `shutdown()` (flush with 3 s timeout). Suite `RuntimeTests` (fixture sensors, in-memory store: 10 ticks ⇒ 10 rows; pause ⇒ none; shutdown flushes).
- [ ] **T3 Fixtures.** `idle`, `load-8core`, `many-helpers` (Electron/Chrome-style app), `sleep-wake` (user-triggered) into `Tests/MonitorEngineTests/Fixtures/recorded/` (< 2 MB each). Unblocks W1 T16.
- [ ] **T4 perf.sh** (`--mock`, `--interactive` via `--open-dashboard processes`); writes `docs/perf/<date>-<cp>.md`.
- [ ] **T5 Interval/App Nap check.** Background `frame.interval` median/p95 over 10 min → W4 T10 decision.
- [ ] **T6 Drills.** `TELLTALE_DISABLE_SENSORS=coalitions,soc,smc,networkFlows,temperatures` ⇒ "—" + tooltips, restricted rows stay `.restricted`, alerts calm; crash canary: `scripts/run.sh --crash-sensor smc` (DEBUG; AppEnvironment → `TelltaleRuntime.make(crashSensor:)` → `SensorFactory.crashing` → `CrashingSensor` aborts in the first `prepare()`) ⇒ next launch shows "Disabled after a crash"; re-enable in Settings.
- [ ] **T7 Soak.** 8 h live: RSS drift < 10 MB, DB within projection, `leaks Telltale | tail -3` = 0.
- [ ] **T8 Checkpoints CP2–CP5**; findings → ICRs/bugs to owners.

**Verification:** `scripts/test.sh RuntimeTests`; reports in `docs/perf/`.

---

## Integration schedule

Merge order:
1. **W0a** → tag `w0a` (W1, W2, W6a start); **W0b** → tag `cp0` (W3, W4, Wm, W5 start).
2. **W1 T1** (MonitorLive), **Wm T1–T3**, **W3 T1–T4**, **W4 T1**, **W7 T2** — as ready.
3. **W3 T5–T12**, **W4 T2–T9**, **Wm T4**, **W5a/b/c** page by page.
4. **W1 T2–T15** → **W7 T1** (stub store).
5. **W2** → W7 switches to the real store.
6. **W6a** → CP2. Then **W6b / W6c / W6d** as findings allow.
7. **W7 T3** → **W1 T16**.
8. Polish → CP5.

Checkpoints (integrator; full `swift test` at each — reason: shared-infrastructure merge point):

| CP | When | Steps | Pass |
|---|---|---|---|
| **CP0** | W0a + W0b | `swift build`; `scripts/build.sh`; `scripts/run.sh` | builds from CLI; status item appears; weak dylib load commands present |
| **CP1** mock app | W1 T1, Wm, W3 A + T7, W4 T1–T6, first W5 pages | `scripts/run.sh --mock calm` / `thermalFair` / `thermalCritical` / `collecting` / `sensorsUnavailable` / `restricted`; `scripts/render.sh popover-alert thermalFair` vs reference | glyph states; banner copy; rows expand to top 3; 1 s ↔ 5 s in log; "—" + tooltips; restricted rows per ARCHITECTURE §5.5 |
| **CP2** live core | W1 all, W6a, W7 T1–T2 | live 2 min vs `top`/`ps`; `scripts/perf.sh 10` | top-5 apps match `top` (±30 %); helpers grouped; root processes present with coalition values; Σ app CPU ≈ system CPU (±15 %, no double count); perf reported |
| **CP3** history | + W2, W5c T4, W7 | live 30 min; quit/relaunch; ranges; `telltale-probe --maintain-now`; scrub; Export CSV | survives relaunch; pause gap; treemap follows scrub; CSV columns; DB size logged; quit flushes via terminateLater |
| **CP4** all sensors | + W6b, W6c, W6d | every page live; inspector connections; actions on TextEdit; W7 T6 drills; `scripts/perf.sh 10` + `--interactive 2` | only documented "—"; root rows not controllable; perf delta vs CP2 reported |
| **CP5** design sign-off | all pages | `scripts/render.sh --all` vs `docs/design/reference/*`; goldens; W7 T7 soak | structure/tokens/copy match or ruling-justified; goldens committed; soak within limits |

---

## Unresolved questions

None blocking. Tracked risks: (1) `ri_energy_nj` may exclude GPU energy (W6a T8 → ICR if so); (2) GPU MHz unresolved on M1 Max (shows "—"); (3) coalition leader-pid discovery method not yet documented in findings (W6a T2 decides; `leaderPID` is optional).
