# Telltale — Architecture

Status: binding for M1+ (revision 2: review fixes + M0 findings applied). Inputs: `SPEC.md` (incl. Design reference + Rulings), M0 spike plan, `docs/findings/*.md`, `docs/design/DESIGN.md` (tokens/components/screens), `docs/design/artboards/*.dc.html`, reference renders `docs/design/reference/<Artboard>@2x.png` (produced by the design agent).
Work breakdown: `docs/superpowers/plans/2026-09-24-parallel-build-plan.md`.

Contents: 1 Build · 2 Module layout · 3 Data flow · 4 Concurrency · 5 Interfaces (locked) · 6 Errors/unavailable · 7 Performance · 8 Testing + design verification · 9 Change control · 10 Rulings applied

---

## 1. Build system

**Decision: XcodeGen (`project.yml`) for the thin app target + local SwiftPM package `MonitorCore` holding ~95% of the code, UI included.**

- `xcodegen` 2.46.0 is installed. `Telltale.xcodeproj` is **generated and gitignored**: no `.pbxproj` conflicts across worktrees; `App/Sources/**` is globbed.
- A real app target (not SwiftPM + hand-assembled bundle) because we need `LSUIElement`, ad-hoc signing that `SMAppService.mainApp` accepts, an asset catalog, and correct linking of the package's private libraries into a bundle.
- UI lives in the package (`MonitorUIKit`, `MonitorScreens`), not `App/`: `swift build`/`swift test` compile and snapshot-test every view headlessly per worktree. `App/` is the AppKit shell + composition root. (Deviation from SPEC "Structure", for testability.)
- Swift 6 language mode everywhere except `CPrivate` (C).
- **Private libraries are weak-linked** so a missing/renamed library on a future macOS makes one sensor unavailable instead of failing app launch: `CPrivate` `linkerSettings: [.unsafeFlags(["-weak-lIOReport", "-F/System/Library/PrivateFrameworks", "-weak_framework", "NetworkStatistics"])]`. Every private declaration carries `__attribute__((weak_import))`; each header exposes `static inline bool tt_<lib>_available(void)` (address-of-symbol != NULL) that the sensor's `prepare()` checks → `.unavailable("… not present on this macOS")`. No `-lsysmon` (libsysmon is unusable, §10). Public frameworks are declared on `MonitorSensors`: `.linkedFramework("IOKit")`, `("CoreWLAN")`, `("SystemConfiguration")`.
- `unsafeFlags` is legal for a local package; W0b T0b.2 verifies it survives `xcodebuild`. Fallback if Xcode rejects it: move the same flags to `OTHER_LDFLAGS` in `project.yml` (and keep them in `Package.swift` for `swift test`).

| Command | What | Owner |
|---|---|---|
| `scripts/gen.sh` | `xcodegen generate --spec project.yml --quiet` | W0 |
| `scripts/build.sh` | gen + `xcodebuild -project Telltale.xcodeproj -scheme Telltale -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build`; prints only `error:`/`warning:`/`BUILD` + app path | W0 |
| `scripts/test.sh <filter…>` | `cd MonitorCore && swift test --filter <filter> 2>&1 \| tail -25` per filter | W0 |
| `scripts/ci.sh <suites…>` | merge gate: `swift build` (all targets) + `scripts/build.sh` + `scripts/test.sh <suites>` + `grep -rn '&-' MonitorCore/Sources --include='*.swift' \| grep -v RateCalculator.swift` must be empty | W0 |
| `scripts/run.sh [--mock <scenario>] [args]` | kill running Telltale; `open -n .build/xcode/Build/Products/Debug/Telltale.app --args …` with `TELLTALE_DATA_DIR=$PWD/.build/data` | W4 |
| `scripts/install.sh` | release build → `~/Applications/Telltale.app` (stable path for launch at login) | W4 |
| `scripts/render.sh <screen> <scenario>` | `swift run telltale-render …` → `.build/renders/<screen>-<scenario>.png` | W3 |
| `scripts/probe.sh [args]` | `swift run -c release telltale-probe …` | W7 |
| `scripts/perf.sh [min] [--mock] [--interactive]` | launch app, 60 s warm-up, sample `ps -o %cpu=,rss=` every 5 s; avg/p95 CPU, max RSS | W7 |

`project.yml` essentials (W0 minimal, W4 owns):

```yaml
name: Telltale
options: { bundleIdPrefix: dev.telltale, deploymentTarget: { macOS: "14.0" }, createIntermediateGroups: true }
settings:
  base: { SWIFT_VERSION: "6.0", ARCHS: arm64, CODE_SIGN_IDENTITY: "-", CODE_SIGN_STYLE: Manual,
          ENABLE_HARDENED_RUNTIME: NO, MARKETING_VERSION: "0.1.0", CURRENT_PROJECT_VERSION: "1" }
packages: { MonitorCore: { path: MonitorCore } }
targets:
  Telltale:
    type: application
    platform: macOS
    sources: [App/Sources, App/Resources]
    info:
      path: App/Info.plist
      properties: { LSUIElement: true, CFBundleDisplayName: Telltale, LSMinimumSystemVersion: "14.0" }
    dependencies:
      - package: MonitorCore
        products: [MonitorModel, MonitorLive, MonitorRuntime, MonitorScreens, MonitorUIKit]   # app imports each explicitly
```

Bundle id `dev.telltale.Telltale`. No sandbox, no entitlements file.

---

## 2. Module layout

```
system-monitor/
  project.yml                      (Telltale.xcodeproj generated, gitignored)
  scripts/
  App/
    Info.plist, Resources/Assets.xcassets
    Sources/
      main.swift, AppDelegate.swift
      Composition/AppEnvironment.swift        args/env, SettingsStore, runtime wiring
      StatusItem/StatusItemController.swift
      Popover/PopoverPanelController.swift    borderless NSPanel under the status item
      Dashboard/DashboardWindowController.swift
      Settings/SettingsWindowController.swift, SettingsStore.swift
      Services/ProcessActionsLive.swift, LaunchAtLogin.swift, VisibilityTracker.swift, PowerEvents.swift
  MonitorCore/
    Package.swift
    Sources/
      CPrivate/                    C: private decls (weak_import) + SMC shim
        include/Responsibility.h Coalition.h        (W6a)
        include/IOReport.h HIDPrivate.h SMC.h       (W6b)   smc.c (W6b)
        include/NStat.h                             (W6c)
        shim.c                                      (W0)
      MonitorModel/                pure Foundation; ALL shared value types + protocols (locked)
        Basics/ Identifiers.swift Time.swift Metrics.swift Units.swift Availability.swift
        Readings/ Process.swift Coalition.swift RootMemory.swift HostCPU.swift Memory.swift SoC.swift
                  GPUClients.swift Temperature.swift SMC.swift Network.swift Disk.swift Power.swift Device.swift
        Snapshots/ SystemFrame.swift CPU.swift GPU.swift Memory.swift Network.swift Thermals.swift
                   Power.swift Disk.swift ProcessSample.swift AppSample.swift Connection.swift
        Sensors/ Sensor.swift SensorSuite.swift RawTick.swift Sampling.swift
                 BuiltinSensors.swift       UnavailableSensor, FixtureSensor, CrashingSensor (only home)
        Alerts/ Alert.swift HistoryEvent.swift
        History/ HistoryProvider.swift HistoryRecord.swift (incl. RecordBatch) EmptyHistoryProvider.swift
        Services/ ProcessActions.swift AppCommands.swift Preferences.swift Navigation.swift
      MonitorLive/                 UI-facing state (depends on MonitorModel only)
        RingBuffer.swift LiveHistory.swift LiveModel.swift
      MonitorEngine/               sampling loop, rates, attribution, assembly, alerts
        Rates/ RateCalculator.swift CPUTicks.swift
        Grouping/ AppResolver.swift AppGrouper.swift
        Attribution/ CoalitionAttributor.swift EnergyAttributor.swift SessionAccumulator.swift
        Assembly/ FrameAssembler.swift ProcessAssembler.swift SystemAssembler.swift
        Records/ RecordBuilder.swift
        Alerts/ AlertEngine.swift EventDetector.swift
        Sampling/ SamplingEngine.swift SensorSlot.swift CrashCanary.swift
      MonitorSensors/
        Process/ ProcessTableSensor.swift CoalitionSensor.swift RootMemorySensor.swift
        Host/ HostCPUSensor.swift MemorySensor.swift DeviceInfoSensor.swift SleepAssertionSensor.swift
        SoC/ IOReportSensor.swift GPUClientsSensor.swift PStateCatalog.swift Resources/pstates.json
        Thermal/ HIDTemperatureSensor.swift SMCSensor.swift SMCDecoder.swift ThermalStateSensor.swift
                 TemperatureCatalog.swift Resources/temperature-catalog.json
        Power/ BatterySensor.swift
        Network/ NStatSensor.swift InterfaceSensor.swift WiFiSensor.swift LatencyProbe.swift ReverseDNS.swift
        Disk/ DiskIOSensor.swift VolumeSensor.swift SMARTSensor.swift
        Support/ <Stream>+<Topic>.swift (per stream, e.g. W6a+KinfoProc.swift)
        LiveSensorFactory.swift    references every adapter type by name (W0, then integrator)
      MonitorStore/  Database.swift Schema.swift HistoryStore.swift Rollup.swift Retention.swift Queries.swift CSVExporter.swift
      MonitorUIKit/
        Tokens/ Format/ Components/ Charts/ Treemap/ Glyph/ Environment/ Snapshot/SnapshotRenderer.swift
      MonitorSnapshotTesting/      test-support library (imports Testing): assertSnapshot, PNG diff; never linked by the app
      MonitorScreens/
        Shell/ DashboardRoot.swift Sidebar.swift DeviceHeader.swift PageHeader.swift NavigationModel.swift
               SettingsView.swift ScreenCatalog.swift
        Popover/ PopoverRoot.swift
        Pages/ OverviewPage.swift CPUPage.swift GPUPage.swift MemoryPage.swift NetworkPage.swift
               ThermalsPage.swift PowerPage.swift DiskPage.swift
               Processes/ ProcessesPage.swift ProcessTableModel.swift AppInspector.swift
               History/ HistoryPage.swift HistoryModel.swift TimeTravelTreemap.swift
      MonitorMocks/  MockDataProvider.swift MockScenarios.swift MockHistoryProvider.swift ActionLog.swift
      MonitorRuntime/ TelltaleRuntime.swift (façade) LivePipeline.swift MockPipeline.swift
      telltale-render/main.swift   screens/components → PNG, --compare
      telltale-probe/main.swift    live sensors headless: bench, dump, record fixtures
    Tests/
      MonitorModelTests/  MonitorLiveTests/  MonitorEngineTests/ (+Fixtures/, Fixtures/recorded/)
      MonitorStoreTests/  MonitorUIKitTests/ (+__Snapshots__)  MonitorScreensTests/ (+__Snapshots__)
      MonitorSensorsTests/ (+Fixtures/<stream>/, e.g. Fixtures/W6b/)  MonitorMocksTests/  MonitorRuntimeTests/
      MonitorScreensTests/Support/ (shared screen-test helpers, W4)
  Spikes/   docs/{ARCHITECTURE.md, design/, findings/, icr/, perf/, superpowers/plans/}
```

Target graph (Package.swift, W0):

```
CPrivate        (C)                                         linkerSettings: weak private libs
MonitorModel    → —                                         Foundation
MonitorLive     → MonitorModel                              + Observation
MonitorEngine   → MonitorModel
MonitorSensors  → MonitorModel, CPrivate                    + IOKit, CoreWLAN, SystemConfiguration; resources: SoC/Resources, Thermal/Resources
MonitorStore    → MonitorModel, GRDB (from: "7.0.0")
MonitorUIKit    → MonitorModel                              + SwiftUI, Charts, AppKit
MonitorSnapshotTesting → MonitorUIKit                       + Testing (used only by UIKit/Screens test targets)
MonitorMocks    → MonitorModel
MonitorScreens  → MonitorModel, MonitorLive, MonitorUIKit, MonitorMocks
MonitorRuntime  → MonitorModel, MonitorLive, MonitorEngine, MonitorSensors, MonitorStore, MonitorMocks
telltale-render → MonitorScreens, MonitorUIKit, MonitorMocks, MonitorLive
telltale-probe  → MonitorEngine, MonitorSensors, MonitorStore   (builds SensorFactory.live itself; uses sampleOnceRaw)
App (Xcode)     → MonitorModel, MonitorLive, MonitorRuntime, MonitorScreens, MonitorUIKit
```

Rules: UI targets never import `MonitorEngine`, `MonitorSensors` or `MonitorStore`; they see data only through `LiveModel` and `HistoryProvider`.

---

## 3. Data flow

```
 sampler executor (DispatchSerialQueue)                                                    MainActor
 ┌───────────────┐ SensorResult<R>  ┌─────────┐ FrameAssembler ┌─────────────┐ liveFrames ┌───────────┐ ┌───────┐
 │ SensorSlot×20 │ ───────────────▶ │ RawTick │ ─────────────▶ │ SystemFrame │ ─────────▶ │ LiveModel │▶│ Views │
 └───────────────┘ (capturedNs,     └─────────┘  rates          └──────┬──────┘ newest(1)  └─────┬─────┘ └───────┘
   cadence, cache,  backoff, cost)                grouping             │                         └──▶ StatusItemController
                                                  coalition residual   ├─▶ AlertEngine ─▶ EventDetector
                                                  energy attribution   ▼
                                                                  RecordBuilder ─▶ RecordBatch ─▶ HistoryStore actor
                                                                                   (unbounded)     buffer → flush 30 s
                                                                                                   rollup/retention 5 min
                              HistoryProvider (async reads) ◀──────────────────────────────────── GRDB DatabasePool (WAL)
```

Per tick (`SamplingEngine.tick()`):
1. `ctx = SampleContext(uptimeNs, wallTime, mode, demand, alertLevel)`. The engine adds `.memoryAlert` to `demand` while the memory arc is ≥ elevated.
2. Each due slot returns `SensorResult<R>`: `.fresh(r, capturedNs)` (new data), `.cached(r, capturedNs)` (not due, or async source whose next result isn't ready), `.failed`, `.notRequested`.
3. `RawTick` (Codable fixture format).
4. `FrameAssembler.assemble(tick)`:
   - rates via `RateCalculator`, always timed by the reading's `capturedNs`, recomputed only when `capturedNs` advances (a cached reading yields the previous rate);
   - process list (sysctl) + rusage v6 enrichment → `ProcessSample`s (`provenance = .measured` or `.restricted`);
   - `CoalitionAttributor`, **only for coalitions with ≥ 1 `.restricted` member** (coalition and rusage meters disagree by ~1 % CPU and ~20 % energy, so all-visible coalitions are left to rusage): residual = Δcoalition − Σ Δvisible members (clamped ≥ 0) for CPU and disk; one restricted member ⇒ filled (`.coalition`); otherwise ⇒ one synthetic row per coalition named after the leader's `p_comm`, in the leader's app (or "System" if no leader);
   - `EnergyAttributor`, in this order: (1) measured v6 `ri_energy_nj` for permitted pids; (2) coalition energy residual for restricted members of those same coalitions (**disabled when v6 is unavailable**, since the residual would then equal the whole coalition and double-count with step 3); (3) SoC share (IOReport CPU/GPU W × share) fills only the pids still `nil`;
   - per-app GPU from AGX only (per client → per pid; covers root pids; coalition `gpu_time` is not used — unknown unit), network (NStat per `ProcessID`), memory (footprint, or `ps` RSS for restricted pids while `rootMemory` runs);
   - grouping by responsible PID (`AppGrouper`), `SessionAccumulator` (per-`AppKey` CPU time, GPU time, net bytes since launch);
   - system snapshots + `SystemMetrics`.
5. `AlertEngine.update` → `AlertState` + transition events; `EventDetector.update` → episodes.
6. Yield frame to `liveFrames` (bufferingNewest 1). Yield `RecordBatch` to `records` unless paused.
7. Sleep until next deadline (cancellable, §4).

Modes: `background` 5 s, `interactive` 1 s, `paused` (no sampling, no records; `samplingPaused` event; charts show a gap). Sleep/wake: baselines reset, `systemSleep` event; first post-wake frame has no rates.

---

## 4. Concurrency model (Swift 6 strict)

| Component | Isolation | Notes |
|---|---|---|
| `SamplingEngine` | `actor` with custom executor = `DispatchSerialQueue(label: "dev.telltale.sampler", qos: .utility)` | Blocking IOKit/mach/CF calls run on our queue, not the cooperative pool. |
| Sensors | owned by the engine actor, **non-Sendable** classes, never escape | Built inside the actor via `SensorFactory.make` (`@Sendable (Set<SensorID>) -> SensorSuite`). |
| Callback-driven state (NStat, RootMemory `ps`, LatencyProbe, ReverseDNS, SMC key sweep) | a separate `final class <X>Box: Sendable` holding only `let` properties: a private `DispatchQueue` and `OSAllocatedUnfairLock<State>` (State: Sendable) | C blocks / `DispatchQueue.async` closures capture only the box (Sendable) — no `@unchecked Sendable` needed. `Mutex` is macOS 15+, so not used. |
| Snapshots, readings, records, events | `struct … : Sendable, Codable, Equatable` | CoW arrays: sending a frame is O(1). |
| Assembler, `RateCalculator`, attributors, `AlertEngine`, `EventDetector`, `RecordBuilder` | plain structs mutated inside the engine actor | Pure, unit-tested without concurrency. |
| `HistoryStore` | `actor` over GRDB `DatabasePool` (Sendable) | Writes via `try await pool.write`, reads via `pool.read` concurrently (WAL). |
| `LiveModel`, `NavigationModel`, `SettingsStore`, controllers, views | `@MainActor` (`@Observable` for models) | One consumer `Task { @MainActor in for await f in pipeline.liveFrames { live.apply(f) } }`. |
| Service closures (`ProcessActions`, `AppCommands`) | `Sendable` structs of `@MainActor @Sendable` closures | Environment-injected. |

Loop wake-up (spelled out): the loop stores `private var sleeper: Task<Void, Never>?`. Each iteration: `let t = Task { try? await Task.sleep(until: deadline, tolerance: interval / 10, clock: .continuous) }; sleeper = t; await t.value`. Awaiting suspends the actor, so `setVisibility`/`setPaused`/`systemDidWake` run meanwhile; they update mode/demand and call `sleeper?.cancel()`, which ends the sleep early. The loop then recomputes: entering `interactive` samples immediately; `paused` sleeps with a 1 h deadline (cancellable) and takes no samples.

Termination: `AppDelegate.applicationShouldTerminate` returns `.terminateLater`, then `Task { await runtime.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }`. `shutdown()` stops the engine, flushes the store (bounded by a 3 s timeout, then replies anyway).

Bans: `@unchecked Sendable` outside `MonitorMocks`; `nonisolated(unsafe)` (except C globals); `DispatchQueue.main.sync`; `MainActor.assumeIsolated` outside AppKit delegate callbacks; unexplained `Task.detached`; wrapping subtraction `&-` outside `RateCalculator.swift` (CI grep).

---

## 5. Interfaces (locked after W0; change only via §9)

Conventions:
- Ratios 0…1 are `Double` named `…Fraction` or `usage`. **Exception:** process/app `cpuPercent` and `gpuPercent` use Activity-Monitor semantics (100 = one core; for GPU, 100 = the whole GPU, since AGX per-client time shares the device).
- Bytes `UInt64`; rates `Double` bytes/s; temperature °C; power W; frequency MHz; CPU/GPU time ns; monotonic time ns (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`).
- `nil` = unavailable/unknown → "—" + tooltip. Never `0` for unknown.
- Every public struct has an explicit `public init` with defaults for all fields.
- Counter deltas go only through `RateCalculator` (reset-safe); no `&-` elsewhere.

### 5.1 Identity & grouping (`MonitorModel/Basics/Identifiers.swift`)

```swift
public struct ProcessID: Hashable, Sendable, Codable {
    public var pid: Int32
    public var startTimeUs: UInt64            // kinfo_proc p_starttime (µs since epoch); 0 = unknown
    // ProcessID(pid, 0) (start time unknown, e.g. NStat before resolution) matches the live process with that pid
    // in the current process list (any start time); if none exists, its data goes to AppKey.system (unattributed).
    public static func coalitionResidual(_ coalitionID: UInt64) -> ProcessID   // pid -1, startTimeUs = id
    public var isSynthetic: Bool { get }      // pid < 0
}

public struct AppKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable { case app, process, system, other }
    public let kind: Kind
    public let id: String     // app: bundle id (fallback bundle path); process: executable path; "system"; "other"
    public init(kind: Kind, id: String)
    public static let system: AppKey, other: AppKey
}

public struct AppIdentity: Hashable, Sendable, Codable {
    public var key: AppKey
    public var displayName: String            // "Final Cut Pro", "System", "node"
    public var bundlePath: String?
}

public enum Category: String, CaseIterable, Sendable, Codable { case cpu, gpu, memory, network, thermals, power, disk }
public enum IconArc: String, CaseIterable, Sendable, Codable { case cpu, gpu, memory, network, thermals }

public enum Provenance: String, Sendable, Codable {
    case measured      // per-pid counters readable (own uid, or rusage permitted)
    case coalition     // counters filled from the process's resource-coalition residual (estimated)
    case restricted    // EPERM, not individually attributable; its usage is in a coalition residual row
}
public enum MemorySource: Sendable, Codable, Hashable {
    case footprint                 // ri_phys_footprint
    case rss(ageNs: UInt64)        // from /bin/ps (restricted pids); age since the ps run
}
```

Grouping (W1 `AppResolver`/`AppGrouper`) — **group by responsible PID**:
1. `r = responsiblePID ?? pid`; path of `r` (cached per `ProcessID`; `nil` if EPERM).
2. Path contains `.app/` → outermost `.app` → `AppKey(.app, bundleID ?? bundlePath)`, name `CFBundleDisplayName ?? CFBundleName ?? filename`.
3. Else (bundle-less, any uid — daemons like WindowServer, kernel_task, mds_stores, and user executables incl. `/usr/local/*`, Homebrew) → `AppKey(.process, path ?? p_comm)`, name = executable name (ruling 2026-09-24, DESIGN §3.12: bundle-less daemons are their own rows). If the responsible pid's path is unreadable (EPERM) use its `p_comm` from `KERN_PROC_ALL`; never fall back to the child's path.
4. Else (no path and no name) → `.system` ("System").
5. Synthetic coalition rows: app of the coalition leader via rules 1–4; no leader → `.system`.
6. AGX clients whose creator pid is gone → `.system`.

```swift
public protocol AppResolving: AnyObject {              // MonitorEngine
    func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity
    func prune(keeping live: Set<ProcessID>)
}
public final class BundleAppResolver: AppResolving { public init(currentUID: uid_t = getuid()) }
public final class FixtureAppResolver: AppResolving { public init(_ map: [Int32: AppIdentity]) }
```

### 5.2 Time, sampling, metrics (`Basics/Time.swift`, `Basics/Metrics.swift`, `Sensors/Sampling.swift`)

```swift
public enum SamplingMode: String, Sendable, Codable { case background, interactive, paused
    public var interval: Duration? { get }                  // 5 s, 1 s, nil
}

public struct SamplingDemand: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt32
    public static let perCore, connections, rawTemperatures, wifi, smart, volumes, sleepAssertions: SamplingDemand
    public static let processTable: SamplingDemand          // a visible process table (enables rootMemory)
    public static let memoryAlert: SamplingDemand           // engine-set while memory arc ≥ elevated (enables rootMemory)
    public static let none: SamplingDemand = []
}

public struct UIVisibility: Sendable, Equatable {
    public var popoverOpen: Bool
    public var dashboardVisible: Bool                       // visible && !occluded && !miniaturized
    public var page: DashboardPage?
    public var inspectedApp: AppKey?                        // connections are collected only for this app
    public var mode: SamplingMode { get }
    public var demand: SamplingDemand { get }
    // page → demand: overview/gpu/power/disk → .processTable; cpu → .perCore+.processTable;
    // memory → .processTable; network → .wifi+.processTable; thermals → .rawTemperatures;
    // disk → +.smart+.volumes; power → +.sleepAssertions; processes → .processTable;
    // inspectedApp != nil → +.connections
}

public enum HistoryRange: String, CaseIterable, Sendable, Codable {
    case live, hour, day, week, month                       // Live / 1H / 24H / 7D / 30D
    public var duration: Duration? { get }
    public var label: String { get }
    public var displayBucket: Duration { get }              // DESIGN.md §5.10: 1H 15 s, 24H 5 min, 7D 30 min, 30D 2 h
}

public enum HistoryMetric: String, CaseIterable, Sendable, Codable {
    case cpuUsage, cpuUser, cpuSystem, cpuPCluster, cpuECluster, loadAvg1
    case gpuUsage, gpuFrequency
    case memUsed, memApp, memWired, memCompressed, memPressure, swapUsed
    case netRx, netTx, netLatency
    case diskRead, diskWrite, diskReadIOPS, diskWriteIOPS
    case socTemp, cpuPTemp, cpuETemp, gpuTemp, ssdTemp, batteryTemp, fan1RPM, fan2RPM
    case packageWatts, cpuWatts, gpuWatts, aneWatts, dramWatts, systemWatts, batteryPercent
    case thermalPressure
    public var sources: [SensorID] { get }                  // for unavailableReason
}
public enum AppMetric: String, CaseIterable, Sendable, Codable {
    case cpu, gpu, memory, netRx, netTx, diskRead, diskWrite, energy
    public var sources: [SensorID] { get }
}

public protocol MetricKey: CaseIterable, Hashable, Sendable, Codable, RawRepresentable where RawValue == String {
    /// Case → storage slot, computed once. Generic types can't hold static stored properties, so each
    /// concrete enum provides it: `static let ordinals = Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })`.
    static var ordinals: [Self: Int] { get }
    static var count: Int { get }
}
extension HistoryMetric: MetricKey {}   // static let ordinals, static let count
extension AppMetric: MetricKey {}

/// Fixed-size, allocation-free row (ContiguousArray<Double>, NaN = missing). Subscript uses Key.ordinals (no allCases scan).
/// Codable **by rawValue** as a keyed container {"cpuUsage": 0.42, …}; NaN omitted; unknown keys ignored,
/// so fixtures survive enum reordering and additions. Hashable/Equatable treat NaN slots as equal (bit-pattern compare).
public struct MetricVector<Key: MetricKey>: Sendable, Codable, Hashable {
    public init()
    public subscript(_ key: Key) -> Double? { get set }
}
public typealias SystemMetrics = MetricVector<HistoryMetric>
public typealias AppMetrics = MetricVector<AppMetric>

public struct SeriesPoint: Sendable, Codable, Equatable { public var time: Date; public var value: Double? }  // nil = gap
```

### 5.3 Raw readings (`MonitorModel/Readings/*`)

Sensors do FFI + source-specific decoding only (including data-driven name/key → group mapping). No deltas except where the source is inherently delta-based (IOReport).

```swift
// Process table: sysctl KERN_PROC_ALL is the list (all pids, incl. root); rusage v6 enriches permitted pids.
public struct RawProcess: Sendable, Codable, Hashable {
    public var id: ProcessID                      // pid + p_starttime
    public var ppid: Int32, uid: UInt32
    public var comm: String                       // p_comm (≤ 16 chars, always available)
    public var name: String?                      // proc_name full name when permitted
    public var path: String?                      // proc_pidpath (nil if EPERM — W6a verifies on root pids)
    public var responsiblePID: Int32?
    public var cpuTimeNs: UInt64?                 // rusage v6 user+system (mach ticks → ns)
    public var footprint: UInt64?
    public var diskReadBytes: UInt64?, diskWriteBytes: UInt64?
    public var energyNJ: UInt64?                  // rusage v6 ri_energy_nj (ri_billed_energy is dead: 0)
    public var threads: Int32?
    public var restricted: Bool                   // rusage EPERM (~330/920 pids without root)
}
public struct ProcessTableReading: Sendable, Codable { public var processes: [RawProcess] }

// Resource coalitions (private, no root): CPU/energy/disk/GPU for root processes.
public struct CoalitionUsage: Sendable, Codable, Hashable {
    public var id: UInt64
    public var leaderPID: Int32?
    public var memberPIDs: [Int32]                // via proc_pidinfo(PROC_PIDCOALITIONINFO)
    public var cpuTimeNs: UInt64                  // mach ticks → ns
    public var energyNJ: UInt64?                  // energy field per findings (energy[11])
    public var gpuTimeRaw: UInt64?                // gpu_time [8]: unknown unit — recorded for diagnostics, never used
    public var diskReadBytes: UInt64?, diskWriteBytes: UInt64?
}
public struct CoalitionsReading: Sendable, Codable { public var coalitions: [CoalitionUsage] }

// Memory for restricted pids: setuid /bin/ps -axo pid=,rss= (KB → bytes), run on its own queue.
public struct RootMemoryReading: Sendable, Codable { public var rssByPID: [Int32: UInt64] }

public enum CoreKind: String, Sendable, Codable { case performance, efficiency }
public struct CoreTicks: Sendable, Codable, Hashable { public var user, system, idle, nice: UInt64 }
public struct HostCPUReading: Sendable, Codable {
    public var cores: [CoreTicks]; public var coreKinds: [CoreKind]; public var loadAverage: [Double]
}

public enum MemoryPressureLevel: Int, Sendable, Codable, Comparable { case normal = 1, warning = 2, critical = 4 }
public struct MemoryReading: Sendable, Codable {
    public var pageSize: UInt64, total: UInt64
    public var free, active, inactive, speculative, wired, purgeable, fileBacked, anonymous: UInt64
    public var compressorBytes: UInt64, compressedOriginalBytes: UInt64?
    public var pageins, pageouts, swapins, swapouts: UInt64
    public var swapTotal, swapUsed: UInt64, swapFileCount: Int?
    public var pressureLevel: MemoryPressureLevel?, pressureFraction: Double?
}

public enum ClusterKind: String, Sendable, Codable { case performance, efficiency }
public struct ClusterResidency: Sendable, Codable, Hashable {
    public var name: String                       // "ECPU", "PCPU", "PCPU1"
    public var kind: ClusterKind
    public var activeFraction: Double             // 1 − (IDLE|OFF|DOWN residency)
    public var frequencyMHz: Double?, maxFrequencyMHz: Double?   // nil unless PStateCatalog knows this chip
    public var watts: Double?                     // EACC_CPU / PACC*_CPU
}
public struct MediaEngineReading: Sendable, Codable, Hashable { public var name: String; public var activeFraction: Double }
public struct SoCPowerReading: Sendable, Codable {                // IOReport, delta over `interval`
    public var interval: Duration
    public var cpuWatts, gpuWatts, aneWatts, dramWatts: Double?
    public var clusters: [ClusterResidency]
    public var gpuActiveFraction: Double?, gpuFrequencyMHz: Double?, gpuMaxFrequencyMHz: Double?  // MHz unresolved on M1 Max
    public var mediaEngines: [MediaEngineReading]                 // empty unless exposed (ruling)
}

public struct GPUClientCounter: Sendable, Codable, Hashable {
    public var clientID: UInt64                   // IORegistry entry ID of the AGXDeviceUserClient
    public var pid: Int32
    public var creatorName: String                // from "pid 123, Name"
    public var gpuTimeNs: UInt64                  // Σ AppUsage.accumulatedGPUTime for this client
}
public struct GPUClientsReading: Sendable, Codable {
    public var clients: [GPUClientCounter]
    public var deviceUtilization: Double?, inUseSystemMemory: UInt64?
}

public enum TemperatureGroup: String, CaseIterable, Sendable, Codable {
    case cpuPerformance, cpuEfficiency, gpu, soc, ssd, battery, airflow, other
}
public struct RawTemperature: Sendable, Codable, Hashable {
    public var name: String, celsius: Double, group: TemperatureGroup, source: Source
    public enum Source: String, Sendable, Codable { case hid, smc }
}
public struct TemperatureReading: Sendable, Codable { public var sensors: [RawTemperature] }   // HID raw list

public struct RawFan: Sendable, Codable, Hashable { public var index: Int; public var rpm, minRPM, maxRPM: Double; public var name: String? }
public struct SMCReading: Sendable, Codable {
    public var fans: [RawFan]
    public var temperatures: [RawTemperature]     // catalog-mapped T-keys (groups for background + alerts);
                                                  // + all cached T-keys when demand ∋ .rawTemperatures
    public var systemWatts: Double?               // PSTR
    public var adapterWatts: Double?              // PDTR
}

public enum ThermalPressure: Int, Sendable, Codable, Comparable, CaseIterable { case nominal, fair, serious, critical }

public enum TransportProtocol: String, Sendable, Codable { case tcp, udp, quic, other }
public struct ByteCounts: Sendable, Codable, Hashable { public var rx, tx: UInt64 }
public struct FlowCounter: Sendable, Codable, Hashable {
    public var flowID: UInt64
    public var process: ProcessID, effectivePID: Int32?
    public var proto: TransportProtocol
    public var rxBytes, txBytes: UInt64           // cumulative for the flow
    public var localPort: UInt16?, remoteAddress: String?, remotePort: UInt16?   // only with .connections
    public var tcpState: String?, interface: String?
}
public struct NetworkFlowsReading: Sendable, Codable {
    public var flows: [FlowCounter]
    /// Cumulative bytes of removed flows **since sensor start**, per process; entries pruned 10 min after the process exits.
    public var closedBytes: [ProcessID: ByteCounts]
    /// Cumulative bytes of sources retired before their pid could be resolved → assembled into AppKey.system.
    public var unattributedBytes: ByteCounts
}
public enum InterfaceKind: String, Sendable, Codable { case wifi, ethernet, thunderbolt, cellular, other }
public struct InterfaceCounter: Sendable, Codable, Hashable {
    public var bsdName: String, displayName: String, kind: InterfaceKind, isUp: Bool, isPrimary: Bool
    public var rxBytes, txBytes: UInt64, ipv4: String?, linkRateBps: Double?
}
public struct InterfacesReading: Sendable, Codable { public var interfaces: [InterfaceCounter]; public var routerIPv4: String? }
public struct WiFiInfo: Sendable, Codable, Equatable {        // no SSID (ruling)
    public var interface: String, standardLabel: String?, bandGHz: Double?, channel: Int?, channelWidthMHz: Int?
    public var rssi: Int?, noise: Int?, txRateMbps: Double?
}
public struct LatencyReading: Sendable, Codable, Equatable {
    public var target: String, lastRTTms: Double?, minMs: Double?, avgMs: Double?, maxMs: Double?, lossFraction5m: Double?
}

public struct BlockDriverCounter: Sendable, Codable, Hashable {
    public var bsdName: String?, isInternal: Bool
    public var readOps, writeOps, readBytes, writeBytes: UInt64
}
public struct DiskIOReading: Sendable, Codable { public var drivers: [BlockDriverCounter] }
public struct VolumeInfo: Sendable, Codable, Hashable, Identifiable {
    public var id: String, name: String, bsdName: String?, fsType: String?, busLabel: String?
    public var isInternal, isEjectable, isEncrypted: Bool
    public var totalBytes: UInt64, availableBytes: UInt64, availableImportantBytes: UInt64?
    public var purgeableBytes: UInt64? { get }
}
public struct VolumesReading: Sendable, Codable { public var volumes: [VolumeInfo] }
public enum SMARTStatus: String, Sendable, Codable { case healthy, warning, failing, unknown }
public struct SMARTInfo: Sendable, Codable, Equatable {
    public var model: String?, capacityBytes: UInt64?, status: SMARTStatus
    public var percentageUsed: Double?, dataReadBytes: UInt64?, dataWrittenBytes: UInt64?
    public var temperatureC: Double?, powerOnHours: Int?, unsafeShutdowns: Int?, criticalWarning: UInt8?
}

public struct BatteryReading: Sendable, Codable, Equatable {  // AppleSmartBattery ioreg preferred (findings)
    public var present: Bool, percent: Double?, isCharging: Bool, onAC: Bool
    public var minutesToEmpty: Int?, minutesToFull: Int?, cycleCount: Int?
    public var designCapacityWh: Double?, maxCapacityWh: Double?, currentCapacityWh: Double?
    public var voltageV: Double?, amperageA: Double?, temperatureC: Double?, condition: String?
    public var adapterName: String?, lowPowerMode: Bool
}
public struct SleepAssertionsReading: Sendable, Codable { public var byPID: [Int32: [String]] }

public struct DeviceInfo: Sendable, Codable, Equatable {
    public var hwModel: String                    // "MacBookPro18,2" (catalog key)
    public var osBuild: String
    public var modelName: String, chipName: String
    public var performanceCores: Int, efficiencyCores: Int, gpuCores: Int?, neuralEngineCores: Int?
    public var memoryBytes: UInt64, memoryType: String?, memoryBandwidth: String?
    public var bootTime: Date, osVersion: String, hasBattery: Bool, fanCount: Int
    public static let placeholder: DeviceInfo
}
```

### 5.4 Sensor protocol, suite, raw tick (`MonitorModel/Sensors/*`)

```swift
public enum SensorID: String, CaseIterable, Sendable, Codable {
    case processes, coalitions, rootMemory, hostCPU, memory, soc, gpuClients, temperatures, smc, thermalState
    case networkFlows, interfaces, wifi, latency, diskIO, volumes, smart, battery, sleepAssertions, device
}

public enum SensorError: Error, Sendable, Codable, Equatable {
    case unavailable(String)          // permanent for this launch (weak symbol missing, no hardware, struct size mismatch)
    case permissionDenied(String)
    case posix(Int32, String)         // errno + context
    case transient(String)
    case timeout
    public static func fromErrno(_ context: String) -> SensorError   // EPERM/EACCES → .permissionDenied, else .posix
}

public enum SensorStatus: Sendable, Codable, Equatable {
    case ok, degraded(String), unavailable(String), disabled(String)
    public var reason: String? { get }
}

public struct SensorCadence: Sendable, Equatable {
    public var interactive: Duration
    public var background: Duration?                 // nil = never in background
    public var requires: SamplingDemand              // [] = always; else only when demand ∩ requires ≠ ∅
    public static let everyTick: SensorCadence
    public static let once: SensorCadence
    public static func every(_ d: Duration, background: Duration? = nil, requires: SamplingDemand = []) -> SensorCadence
}

public struct SampleContext: Sendable {
    public var uptimeNs: UInt64, wallTime: Date, mode: SamplingMode, demand: SamplingDemand
    public var alertLevel: AlertLevel                // overall level of the previous tick
}

public protocol Sensor<Reading>: AnyObject {
    associatedtype Reading: Sendable & Codable
    var id: SensorID { get }
    var cadence: SensorCadence { get }
    /// Open handles, check weak symbols (`tt_*_available()`). Lazy, on the sampler executor. Cheap:
    /// no sweeps (e.g. SMC reads only hard-coded keys; the full key sweep runs off-queue once and is cached).
    func prepare() throws(SensorError)
    /// Fast; never blocks > 250 ms. Async sources return their last completed result and kick off the next.
    /// Returns the reading and the uptime (ns) at which it was captured.
    func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: Reading, capturedNs: UInt64)
    func invalidate()
}

// MonitorModel/Sensors/BuiltinSensors.swift (the only home of these three)
public final class UnavailableSensor<R: Sendable & Codable>: Sensor { public init(_ id: SensorID, reason: String) }
public final class FixtureSensor<R: Sendable & Codable>: Sensor {
    public init(_ id: SensorID, readings: [Result<R, SensorError>], cadence: SensorCadence = .everyTick)
}
/// Debug hook for the crash canary: forwards to `wrapped`, but calls abort() inside the first prepare().
public final class CrashingSensor<R: Sendable & Codable>: Sensor { public init(wrapping: any Sensor<R>) }

public struct SensorSuite {                           // non-Sendable; lives inside SamplingEngine
    public var processes: any Sensor<ProcessTableReading>
    public var coalitions: any Sensor<CoalitionsReading>
    public var rootMemory: any Sensor<RootMemoryReading>
    public var hostCPU: any Sensor<HostCPUReading>
    public var memory: any Sensor<MemoryReading>
    public var soc: any Sensor<SoCPowerReading>
    public var gpuClients: any Sensor<GPUClientsReading>
    public var temperatures: any Sensor<TemperatureReading>
    public var smc: any Sensor<SMCReading>
    public var thermalState: any Sensor<ThermalPressure>
    public var networkFlows: any Sensor<NetworkFlowsReading>
    public var interfaces: any Sensor<InterfacesReading>
    public var wifi: any Sensor<WiFiInfo>
    public var latency: any Sensor<LatencyReading>
    public var diskIO: any Sensor<DiskIOReading>
    public var volumes: any Sensor<VolumesReading>
    public var smart: any Sensor<SMARTInfo>
    public var battery: any Sensor<BatteryReading>
    public var sleepAssertions: any Sensor<SleepAssertionsReading>
    public var device: any Sensor<DeviceInfo>
    public static func allUnavailable(reason: String) -> SensorSuite
    public func crashing(_ id: SensorID) -> SensorSuite      // wraps that field in CrashingSensor
}
public struct SensorFactory: Sendable {
    public var make: @Sendable (_ disabled: Set<SensorID>) -> SensorSuite
    public init(make: @escaping @Sendable (Set<SensorID>) -> SensorSuite)
    /// `--crash-sensor <id>` (DEBUG builds; parsed by AppEnvironment, passed through TelltaleRuntime.make) → canary drill.
    public func crashing(_ id: SensorID?) -> SensorFactory
}
// MonitorSensors/LiveSensorFactory.swift: public extension SensorFactory { static let live: SensorFactory }

public enum SensorResult<R: Sendable & Codable>: Sendable, Codable {
    case fresh(R, capturedNs: UInt64)
    case cached(R, capturedNs: UInt64)
    case failed(SensorError, last: R?, capturedNs: UInt64?)
    case notRequested
    public var value: R? { get }
    public var capturedNs: UInt64? { get }
}

public struct RawTick: Sendable, Codable {   // fixture format; custom init(from:) uses decodeIfPresent → .notRequested
    public var wallTime: Date, uptimeNs: UInt64, mode: SamplingMode, demand: SamplingDemand
    public var processes: SensorResult<ProcessTableReading>
    public var coalitions: SensorResult<CoalitionsReading>
    public var rootMemory: SensorResult<RootMemoryReading>
    public var hostCPU: SensorResult<HostCPUReading>
    public var memory: SensorResult<MemoryReading>
    public var soc: SensorResult<SoCPowerReading>
    public var gpuClients: SensorResult<GPUClientsReading>
    public var temperatures: SensorResult<TemperatureReading>
    public var smc: SensorResult<SMCReading>
    public var thermalState: SensorResult<ThermalPressure>
    public var networkFlows: SensorResult<NetworkFlowsReading>
    public var interfaces: SensorResult<InterfacesReading>
    public var wifi: SensorResult<WiFiInfo>
    public var latency: SensorResult<LatencyReading>
    public var diskIO: SensorResult<DiskIOReading>
    public var volumes: SensorResult<VolumesReading>
    public var smart: SensorResult<SMARTInfo>
    public var battery: SensorResult<BatteryReading>
    public var sleepAssertions: SensorResult<SleepAssertionsReading>
    public var device: SensorResult<DeviceInfo>
    public var health: [SensorID: SensorStatus]
}
```

Default cadences (W6 may tune; W7 verifies):

| Sensor | interactive | background | requires | measured cost (M1 Max) |
|---|---|---|---|---|
| processes (sysctl + rusage v6) | tick | tick | — | TBD W6a (est. 4–7 ms) |
| coalitions | tick | tick | — | 1.3–2.1 ms (+ membership only for new/exited pids) |
| rootMemory (`ps`) | 30 s | 30 s | `.processTable` or `.memoryAlert` | ~20 ms, off-queue |
| hostCPU, memory, thermalState, interfaces, diskIO | tick | tick | — | < 1 ms total |
| soc (IOReport) | tick | tick | — | ~2 ms |
| gpuClients (AGX) | tick | tick | — | ~2 ms |
| networkFlows (NStat) | tick | **10 s** | — (endpoints only with `.connections`) | 21–28 ms per query, on the box queue |
| smc (fans, catalog T-keys, PSTR/PDTR) | 2 s | 5 s | — | < 1 ms (hard-coded keys) |
| temperatures (HID raw list) | 2 s | never | `.rawTemperatures` | 65–80 ms |
| battery | 5 s | 30 s | — | |
| latency | 10 s | 10 s | — | async |
| wifi | 2 s | 30 s | — | |
| volumes | 10 s | 60 s | — | |
| sleepAssertions | 5 s | 60 s | — | |
| smart | 300 s | never | `.smart` | |
| device | once | once | — | |

### 5.5 Snapshots (`MonitorModel/Snapshots/*`)

```swift
public struct SystemFrame: Sendable, Codable, Equatable {
    public var wallTime: Date, uptimeNs: UInt64, interval: Duration?, mode: SamplingMode
    public var device: DeviceInfo
    public var cpu: CPUSnapshot, gpu: GPUSnapshot, memory: MemorySnapshot, network: NetworkSnapshot
    public var thermals: ThermalSnapshot, power: PowerSnapshot, disk: DiskSnapshot
    public var processes: [ProcessSample]         // incl. synthetic coalition rows; unsorted
    public var apps: [AppSample]                  // sorted by cpuPercent desc
    public var connections: [ConnectionSample]    // only for UIVisibility.inspectedApp
    public var alert: AlertState
    public var events: [HistoryEvent]
    public var sensorHealth: [SensorID: SensorStatus]
    public var metrics: SystemMetrics
    public static let empty: SystemFrame
}

public struct CoreUsage: Sendable, Codable, Hashable { public var index: Int; public var kind: CoreKind; public var usage: Double }
public struct ClusterSnapshot: Sendable, Codable, Hashable {
    public var kind: ClusterKind, coreCount: Int
    public var usage: Double?, activeResidency: Double?, frequencyMHz: Double?, maxFrequencyMHz: Double?, watts: Double?
}
public struct CPUSnapshot: Sendable, Codable, Equatable {
    public var usage: Double?, user: Double?, system: Double?, idle: Double?
    public var cores: [CoreUsage]                 // only with .perCore
    public var clusters: [ClusterSnapshot]
    public var loadAverage: [Double]?, threadCount: Int?, processCount: Int?
}
public struct GPUSnapshot: Sendable, Codable, Equatable {
    public var usage: Double?, frequencyMHz: Double?, maxFrequencyMHz: Double?, watts: Double?
    public var allocatedMemory: UInt64?, coreCount: Int?, aneWatts: Double?, mediaEngines: [MediaEngineReading]
}
public struct MemorySnapshot: Sendable, Codable, Equatable {
    public var total: UInt64, used: UInt64?, appMemory: UInt64?, wired: UInt64?, compressed: UInt64?
    public var cachedFiles: UInt64?, free: UInt64?, compressionRatio: Double?
    public var pressureLevel: MemoryPressureLevel?, pressureFraction: Double?
    public var swapUsed: UInt64?, swapTotal: UInt64?, swapFileCount: Int?
    public var pageInsPerSec: Double?, pageOutsPerSec: Double?, swapInsPerSec: Double?, swapOutsPerSec: Double?
}
public struct InterfaceSnapshot: Sendable, Codable, Hashable, Identifiable {
    public var id: String { bsdName }
    public var bsdName: String, displayName: String, kind: InterfaceKind, isUp: Bool, isPrimary: Bool
    public var rxBps: Double?, txBps: Double?, ipv4: String?, linkRateBps: Double?
}
public struct NetworkSnapshot: Sendable, Codable, Equatable {
    public var rxBps: Double?, txBps: Double?, interfaces: [InterfaceSnapshot]
    public var wifi: WiFiInfo?, routerIPv4: String?, localIPv4: String?, latency: LatencyReading?
}
public struct TemperatureGroupSnapshot: Sendable, Codable, Hashable {
    public var group: TemperatureGroup, average: Double, maximum: Double, sensorCount: Int
}
public struct FanSnapshot: Sendable, Codable, Hashable, Identifiable { public var id: Int, name: String, rpm, minRPM, maxRPM: Double }
public struct ThermalSnapshot: Sendable, Codable, Equatable {
    public var pressure: ThermalPressure?
    public var socAverage: Double?, hottest: RawTemperature?
    public var groups: [TemperatureGroupSnapshot]  // from SMC catalog keys (always)
    public var sensors: [RawTemperature]           // HID + SMC raw list, only with .rawTemperatures
    public var fans: [FanSnapshot]                 // read-only (ruling)
    public var approximateMapping: Bool            // true when hw.model not in the catalog (generic families)
}
public struct BatterySnapshot: Sendable, Codable, Equatable {
    public var percent: Double?, isCharging: Bool, onAC: Bool, timeRemaining: Duration?
    public var healthFraction: Double?, cycleCount: Int?, condition: String?
    public var maxCapacityWh: Double?, designCapacityWh: Double?, currentCapacityWh: Double?
    public var temperatureC: Double?, drainWatts: Double?
}
public struct PowerSnapshot: Sendable, Codable, Equatable {
    public var packageWatts: Double?, cpuWatts: Double?, gpuWatts: Double?, aneWatts: Double?, dramWatts: Double?
    public var systemWatts: Double?                // SMC PSTR
    public var battery: BatterySnapshot?
    public var adapterWatts: Double?, adapterName: String?, lowPowerMode: Bool
}
public struct DiskSnapshot: Sendable, Codable, Equatable {
    public var readBps: Double?, writeBps: Double?, readIOPS: Double?, writeIOPS: Double?
    public var volumes: [VolumeInfo], smart: SMARTInfo?
    public var bootVolume: VolumeInfo? { get }
}

public struct ProcessSample: Sendable, Codable, Hashable, Identifiable {
    public var id: ProcessID
    public var pid: Int32 { get }
    public var name: String, path: String?, user: String?, uid: UInt32
    public var isCurrentUser: Bool
    public var app: AppKey
    public var provenance: Provenance
    public var coalitionID: UInt64?
    public var cpuPercent: Double?, cpuTimeNs: UInt64?, threads: Int32?
    public var memory: UInt64?, memorySource: MemorySource?
    public var gpuPercent: Double?, gpuTimeNs: UInt64?
    public var netRxBps: Double?, netTxBps: Double?, netRxTotal: UInt64?, netTxTotal: UInt64?, connectionCount: Int?
    public var diskReadBps: Double?, diskWriteBps: Double?, diskReadTotal: UInt64?, diskWriteTotal: UInt64?
    public var energyWatts: Double?, energyEstimated: Bool
    public var preventsSleep: Bool
}

public struct AppSample: Sendable, Codable, Hashable, Identifiable {
    public var id: AppKey { identity.key }
    public var identity: AppIdentity
    public var processIDs: [ProcessID]
    public var hiddenProcessCount: Int            // restricted members not individually attributed
    public var coalitionResidual: AppMetrics?     // share that came from synthetic coalition rows
    public var isCurrentUser: Bool
    public var cpuPercent: Double?, gpuPercent: Double?, memory: UInt64?
    public var netRxBps: Double?, netTxBps: Double?, diskReadBps: Double?, diskWriteBps: Double?
    public var energyWatts: Double?, energyEstimated: Bool
    public var cpuTimeNs: UInt64?, gpuTimeNs: UInt64?          // session (since Telltale start)
    public var netRxSession: UInt64?, netTxSession: UInt64?    // "This session"
    public var threads: Int32?, connectionCount: Int?, preventsSleep: Bool
    public var metrics: AppMetrics
    public func value(for metric: AppMetric) -> Double?
}

public struct ConnectionSample: Sendable, Codable, Hashable, Identifiable {
    public var id: UInt64
    public var process: ProcessID, app: AppKey, proto: TransportProtocol
    public var localPort: UInt16?, remoteAddress: String?, remotePort: UInt16?, remoteHost: String?
    public var tcpState: String?, rxBps: Double?, txBps: Double?, rxTotal: UInt64, txTotal: UInt64
}
```

How restricted (root/other-user) processes appear (Processes page, DESIGN §3.12):
- Every pid from the sysctl list is a row. `provenance == .restricted` rows show name (`p_comm`, or path basename if readable), PID, user; CPU/energy/disk "—" with tooltip `unavailableReason` → "Owned by another user; counted in the ‹leader› coalition row".
- `.coalition` rows (the only restricted member of a coalition) show values with the DESIGN.md estimated style and tooltip "Estimated from the process's resource coalition".
- Synthetic rows (`ProcessID.coalitionResidual`) exist only for coalitions with ≥ 1 restricted member and ≠ 1 restricted member; named after the coalition leader's `p_comm` (or "System"), provenance `.coalition`, included in their app's totals in Apps mode.
- GPU for restricted pids comes from AGX like any pid; if `gpuClients` is unavailable it is "—" (no coalition fallback).
- Memory for restricted pids: "—" with tooltip "Appears when the process table is open" until `rootMemory` has run; then value with tooltip "RSS from ps, N s old" (`memorySource = .rss(ageNs:)`).

Category ↔ top-3 key (popover rows, treemap default): cpu → `cpuPercent`; gpu → `gpuPercent`; memory → `memory`; network → `netRxBps + netTxBps`; thermals, power → `energyWatts`; disk → `diskReadBps + diskWriteBps`.

Availability helpers (`MonitorModel/Basics/Availability.swift`, used by every view):

```swift
public func unavailableReason(_ metric: HistoryMetric, health: [SensorID: SensorStatus]) -> String?
public func unavailableReason(_ metric: AppMetric, _ process: ProcessSample, health: [SensorID: SensorStatus]) -> String?
public func unavailableReason(_ metric: AppMetric, _ app: AppSample, health: [SensorID: SensorStatus]) -> String?
```

### 5.6 Engine APIs (`MonitorEngine`, W1)

```swift
/// Counter deltas → per-second rates, timed by capturedNs. First sight → nil; counter decrease (reset/recreated
/// client/pid reuse) → nil + rebaseline; same capturedNs as last call → returns the previous result unchanged.
public struct RateCalculator<Key: Hashable & Sendable>: Sendable {
    public init()
    public mutating func rate(for key: Key, counter: UInt64, capturedNs: UInt64) -> Double?
    public mutating func delta(for key: Key, counter: UInt64, capturedNs: UInt64) -> (delta: UInt64, seconds: Double)?
    public mutating func prune(keeping live: Set<Key>)
    public mutating func reset()
    public var count: Int { get }
}

public enum CPUTicks {
    public static func usage(previous: [CoreTicks], current: [CoreTicks]) -> (perCore: [Double], user: Double, system: Double, idle: Double)?
}

public struct CoalitionDelta: Sendable, Hashable {
    public var cpuNs: UInt64, energyNJ: UInt64?, diskR: UInt64?, diskW: UInt64?, seconds: Double
}
public struct CoalitionDeltas: Sendable {          // per coalition, over the coalition reading's own interval
    public var byID: [UInt64: CoalitionDelta]
    public var membership: [UInt64: CoalitionUsage]
}

/// Runs ONLY for coalitions with ≥ 1 member whose provenance is .restricted (all-visible coalitions: rusage wins).
/// residual = Δcoalition − Σ Δvisible members (clamped ≥ 0) for CPU and disk.
/// Exactly one restricted member → it gets the residual (provenance .coalition).
/// Otherwise → one synthetic ProcessSample per coalition (leader p_comm, leader's app; no leader → .system "System").
/// No GPU: coalition gpu_time has an unknown unit; AGX is the only GPU source.
public struct CoalitionAttributor: Sendable {
    public init(minResidualCPUPercent: Double = 0.5, minResidualWatts: Double = 0.05)
    public mutating func attribute(_ processes: inout [ProcessSample], coalitions: CoalitionDeltas,
                                   identities: [Int32: AppIdentity]) -> [ProcessSample]   // returns synthetic rows
}

/// Order (ruling, N6): (1) measured Δ ri_energy_nj (v6) for permitted pids;
/// (2) coalition energy residual for restricted members, same coalition scope and fill/synthetic rules as CoalitionAttributor —
///     skipped entirely when v6 is unavailable (residual would equal the whole coalition → double count with step 3);
/// (3) SoC share (IOReport cpuW × cpu share + gpuW × gpu share) assigned only to pids still without a value.
public protocol EnergyAttributor: Sendable {
    mutating func watts(processes: [ProcessSample], coalitions: CoalitionDeltas, soc: SoCPowerReading?, dt: Double) -> [ProcessID: Double]
    var usesSoCShareFallback: Bool { get }        // step 3 used this tick → energyEstimated on those rows
}
public struct RulingEnergyAttributor: EnergyAttributor { public init() }

public struct SessionAccumulator: Sendable {       // per AppKey since launch: cpuTimeNs, gpuTimeNs, net rx/tx
    public init()
    public mutating func add(_ apps: [AppSample], processDeltas: [ProcessID: (cpuNs: UInt64, gpuNs: UInt64, rx: UInt64, tx: UInt64)])
    public func totals(_ key: AppKey) -> (cpuNs: UInt64, gpuNs: UInt64, rx: UInt64, tx: UInt64)
}

public struct AppGrouper { public static func group(_ processes: [ProcessSample], identities: [AppKey: AppIdentity]) -> [AppSample] }

public struct FrameAssembler {
    public init(resolver: any AppResolving, energy: any EnergyAttributor = RulingEnergyAttributor(), currentUID: uid_t = getuid())
    public mutating func assemble(_ tick: RawTick, inspectedApp: AppKey?) -> SystemFrame   // alert/events filled by caller
    public mutating func reset()
}

public struct RecordConfig: Sendable {
    public var minCPUPercent = 0.5, minNetBps = 1024.0, minDiskBps = 102_400.0   // any GPU > 0 counts
    public var minMemory: UInt64 = 200 << 20
}
public struct RecordBuilder: Sendable {
    public init(config: RecordConfig = .init())
    public func record(from frame: SystemFrame) -> HistoryRecord
}

public actor SamplingEngine {
    public init(factory: SensorFactory, disabled: Set<SensorID> = [], alertConfig: AlertConfig = .init(),
                recordConfig: RecordConfig = .init(), canary: CrashCanary = .standard)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { get }
    public nonisolated let liveFrames: AsyncStream<SystemFrame>      // bufferingNewest(1)
    public nonisolated let records: AsyncStream<RecordBatch>         // unbounded, ~1 element/tick
    public func start()
    public func stop() async
    public func setVisibility(_ v: UIVisibility)   // cancels the stored sleeper (§4)
    public func setPaused(_ paused: Bool)
    public func systemWillSleep()
    public func systemDidWake()
    public func sampleOnce() -> SystemFrame
    public func sampleOnceRaw() -> (tick: RawTick, frame: SystemFrame)   // telltale-probe --record/--frames
}

final class SensorSlot<R: Sendable & Codable> {    // internal
    init(_ sensor: any Sensor<R>, canary: CrashCanary)
    func sample(_ ctx: SampleContext) -> SensorResult<R>
    var status: SensorStatus { get }
    var costNs: (last: UInt64, mean: UInt64, p95: UInt64) { get }
}
public struct CrashCanary: Sendable { public static let standard: CrashCanary; public static let none: CrashCanary }
```

### 5.7 Live model (`MonitorLive`, W1)

```swift
public enum LivePhase: Sendable, Equatable { case collecting(since: Date), live, paused(since: Date) }

@MainActor @Observable
public final class LiveModel {
    public init(device: DeviceInfo = .placeholder, historyCapacity: Int = 300, appHistoryCapacity: Int = 120)

    // Always updated (status item)
    public private(set) var alert: AlertState
    public private(set) var phase: LivePhase
    public private(set) var samplingInterval: Duration?

    // Updated only while isPresenting; each property is assigned only when the new value != old (no spurious invalidation)
    public var isPresenting: Bool
    public private(set) var device: DeviceInfo
    public private(set) var cpu: CPUSnapshot
    public private(set) var gpu: GPUSnapshot
    public private(set) var memory: MemorySnapshot
    public private(set) var network: NetworkSnapshot
    public private(set) var thermals: ThermalSnapshot
    public private(set) var power: PowerSnapshot
    public private(set) var disk: DiskSnapshot
    public private(set) var processes: [ProcessSample]
    public private(set) var apps: [AppSample]
    public private(set) var connections: [ConnectionSample]      // engine already filtered to the inspected app
    public private(set) var sensorHealth: [SensorID: SensorStatus]
    public private(set) var lastUpdate: Date?

    // Per-category change counters: separate stored properties, one `var` per line (@Observable rejects multi-binding decls)
    public private(set) var cpuVersion = 0
    public private(set) var gpuVersion = 0
    public private(set) var memoryVersion = 0
    public private(set) var networkVersion = 0
    public private(set) var thermalsVersion = 0
    public private(set) var powerVersion = 0
    public private(set) var diskVersion = 0
    public private(set) var appsVersion = 0
    public func version(_ c: Category) -> Int                    // reads the matching counter (tracked)

    // Ring buffers are @ObservationIgnored; readers depend on the category counter
    public func series(_ metric: HistoryMetric, window: Duration = .seconds(60)) -> [SeriesPoint]
    public func appSeries(_ app: AppKey, _ metric: AppMetric, window: Duration = .seconds(60)) -> [SeriesPoint]

    // Derived; cached per apply (@ObservationIgnored storage, tracked via appsVersion)
    public func topApps(_ category: Category, count: Int = 3) -> [AppSample]
    public var topConsumer: AppSample? { get }                   // max energyWatts, fallback cpuPercent; excludes .system/.other
    public func app(_ key: AppKey) -> AppSample?
    public func processes(of app: AppKey) -> [ProcessSample]
    public func status(of sensor: SensorID) -> SensorStatus

    public func apply(_ frame: SystemFrame)
    public func setPaused(_ paused: Bool, at: Date)
}

public struct RingBuffer<Element>: RandomAccessCollection { public init(capacity: Int); public mutating func append(_ e: Element) }
```

### 5.8 Alerts & events (`MonitorModel/Alerts/*`, logic in `MonitorEngine/Alerts`)

```swift
public enum AlertLevel: Int, Sendable, Codable, Comparable { case calm, elevated, critical }

public struct ActiveAlert: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: Sendable, Codable, Equatable {
        case thermalPressure(ThermalPressure), memoryPressure(MemoryPressureLevel), runawayApp(AppKey, cpuPercent: Double)
    }
    public var id: String { get }                 // "thermal" | "memory" | "runaway:<key>"
    public var kind: Kind, level: AlertLevel, arc: IconArc, since: Date
    public var culprit: AppIdentity?, culpritValue: Double?
}
public struct AlertState: Sendable, Codable, Equatable {
    public var level: AlertLevel
    public var arcs: [IconArc: AlertLevel]
    public var active: [ActiveAlert]              // level desc, then since asc
    public var pulseToken: Int                    // +1 on each entry into .critical
    public var paused: Bool                       // glyph dimmed (ruling)
    public static let calm: AlertState
}
public struct AlertConfig: Sendable, Equatable {
    public var runawayEnterCPUPercent: Double = 100          // ruling: ≥ 100 % …
    public var runawayEnterAfter: Duration = .seconds(300)   // … sustained 5 min (every sample in window ≥ threshold)
    public var runawayExitCPUPercent: Double = 80
    public var runawayExitAfter: Duration = .seconds(30)
    public var stepDownHold: Duration = .seconds(10)
    public var runawayExcluded: Set<AppKey> = [.system, .other]
}
public struct AlertEngine: Sendable {
    public init(config: AlertConfig = .init())
    public private(set) var state: AlertState
    public mutating func update(thermal: ThermalPressure?, memory: MemoryPressureLevel?, apps: [AppSample],
                                at now: Date) -> (state: AlertState, events: [HistoryEvent])
    public mutating func setPaused(_ paused: Bool, at now: Date) -> AlertState
}
```

| Input | Level | Arc |
|---|---|---|
| thermal nominal / fair / serious / critical | calm / elevated / critical / critical | thermals |
| memory normal / warning / critical | calm / elevated / critical | memory |
| runaway app (≥ 100 % for 5 min) | elevated | cpu |
| input `nil` | calm (never raises) | — |
| paused | calm, `paused = true` | — |

Step-up immediate; step-down after `stepDownHold` of continuous lower condition; overall = max.

```swift
public struct HistoryEvent: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case thermalPressure, memoryPressure, runawayApp, appEpisode, swapGrowth, samplingPaused, systemSleep
    }
    public var id: UUID, kind: Kind, start: Date, end: Date?, level: AlertLevel
    public var app: AppIdentity?, metric: AppMetric?, peak: Double?, label: String
}
public struct EpisodeConfig: Sendable {
    public var cpuPercent = 200.0, gpuPercent = 30.0, netBps = 10e6, diskBps = 50e6
    public var minDuration: Duration = .seconds(60), mergeGap: Duration = .seconds(30)
}
public struct EventDetector: Sendable {
    public init(config: EpisodeConfig = .init())
    public mutating func update(_ frame: SystemFrame) -> [HistoryEvent]
    public mutating func flush(at: Date) -> [HistoryEvent]
}
```

### 5.9 Store (`MonitorModel/History/*` protocols; `MonitorStore`, W2)

```swift
public struct AppRecord: Sendable, Codable, Equatable { public var identity: AppIdentity; public var metrics: AppMetrics }
public struct HistoryRecord: Sendable, Codable, Equatable {
    public var time: Date, interval: Duration, system: SystemMetrics, apps: [AppRecord]   // above thresholds + .other
}
public struct RecordBatch: Sendable { public var record: HistoryRecord?; public var events: [HistoryEvent] }   // Model (Store has no Engine dep)
public struct AppShare: Sendable, Codable, Hashable, Identifiable {
    public var id: AppKey { identity.key }; public var identity: AppIdentity; public var value: Double; public var fraction: Double
}
public struct AppAggregate: Sendable, Codable, Hashable { public var identity: AppIdentity; public var average, peak: Double; public var total: Double? }
public struct ExportSummary: Sendable, Equatable { public var rows: Int, bytes: Int; public var url: URL }

public protocol HistoryProvider: Sendable {
    /// Bucketed to `bucket` (default range.displayBucket, AVG); gap points (value nil) where a bucket has no rows.
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]]
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [AppMetric: [SeriesPoint]]
    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare]
    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate]
    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double?
    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double?
    func events(in interval: DateInterval) async throws -> [HistoryEvent]
    func coverage() async throws -> DateInterval?
    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary
}
/// Protocol requirements can't have default arguments; these overloads pass bucket: nil (= range.displayBucket).
public extension HistoryProvider {
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date) async throws -> [HistoryMetric: [SeriesPoint]]
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date) async throws -> [AppMetric: [SeriesPoint]]
}
/// MonitorModel/History/EmptyHistoryProvider.swift — default env value and "History unavailable" fallback; returns empty/nil.
public struct EmptyHistoryProvider: HistoryProvider { public init() }

public protocol HistoryRecorder: Sendable {
    func append(_ batch: RecordBatch) async
    func flush() async throws
    func maintain(now: Date) async throws
}

public actor HistoryStore: HistoryProvider, HistoryRecorder {
    public enum Location: Sendable { case file(URL), inMemory }
    public init(location: Location, config: StoreConfig = .init()) throws
    // no flushSync: termination awaits runtime.shutdown() via .terminateLater (§4)
}
public struct StoreConfig: Sendable {
    public var flushInterval: Duration = .seconds(30), flushMaxRecords = 120
    public var rawRetention: Duration = .seconds(86_400)             // full resolution 24 h (ruling)
    public var minuteRetention: Duration = .seconds(7 * 86_400)
    public var quarterRetention: Duration = .seconds(30 * 86_400)
    public var maintenanceInterval: Duration = .seconds(300)
    public var now: @Sendable () -> Date = Date.init
}
```

Schema (GRDB migrator `v1`; `journal_mode=WAL`, `synchronous=NORMAL`, `auto_vacuum=INCREMENTAL`, `cache_size=-2000`):

```sql
app(id INTEGER PRIMARY KEY, key_kind TEXT, key_id TEXT, name TEXT, bundle_path TEXT, UNIQUE(key_kind, key_id))
system_raw(ts INTEGER PRIMARY KEY /*unix ms*/, interval_ms INTEGER, <REAL column per HistoryMetric.rawValue>)
system_1m, system_15m (ts PK = bucket start, n INTEGER, same REAL columns = averages)
app_raw(ts INTEGER, app_id INTEGER, <REAL column per AppMetric.rawValue>, PRIMARY KEY(ts, app_id)) WITHOUT ROWID
app_1m, app_15m (same + n)
event(id TEXT PRIMARY KEY, kind TEXT, start INTEGER, end INTEGER, level INTEGER, app_id INTEGER, metric TEXT, peak REAL, label TEXT)
CREATE INDEX event_start ON event(start)
```

At every open, after migrations, the store compares metric columns with `HistoryMetric.allCases`/`AppMetric.allCases` and runs `ALTER TABLE … ADD COLUMN <name> REAL` for missing ones (additive metrics need no migration). Range → table: hour/day → `*_raw`; week → `*_1m`; month → `*_15m`. Rollups aggregate completed buckets idempotently (`INSERT OR REPLACE … GROUP BY`), then retention deletes. CSV: `time,<metrics…>`, ISO-8601 UTC, streamed via cursor. DB: `$TELLTALE_DATA_DIR/history.sqlite` or `~/Library/Application Support/Telltale/history.sqlite`. Estimate < 60 MB (target < 200 MB).

### 5.10 Services, preferences, navigation (`MonitorModel/Services/*`)

```swift
public enum ProcessTarget: Sendable, Hashable {
    case app(AppIdentity, pids: [Int32])
    case process(pid: Int32, name: String, path: String?, uid: UInt32)
}
public enum ActionResult: Sendable, Equatable { case done, notPermitted, failed(String), cancelled }
public struct ProcessActions: Sendable {
    public var canControl: @MainActor @Sendable (ProcessTarget) -> Bool     // false for root/other users and synthetic rows
    public var quit: @MainActor @Sendable (ProcessTarget) async -> ActionResult
    public var forceQuit: @MainActor @Sendable (ProcessTarget) async -> ActionResult
    public var revealInFinder: @MainActor @Sendable (ProcessTarget) -> Void
    public var openInActivityMonitor: @MainActor @Sendable (ProcessTarget) -> Void
    public var eject: @MainActor @Sendable (VolumeInfo) async -> ActionResult
    public static let noop: ProcessActions
}
public enum DashboardPage: String, CaseIterable, Sendable, Codable {
    case overview, cpu, gpu, memory, network, thermals, power, disk, processes, history
    public var title: String { get }; public var section: Section { get }
    public enum Section: String, Sendable, CaseIterable { case monitor, system, activity }
}
public struct AppCommands: Sendable {
    public var openDashboard: @MainActor @Sendable (DashboardPage?) -> Void
    public var inspectApp: @MainActor @Sendable (AppKey) -> Void
    public var openSettings: @MainActor @Sendable () -> Void
    public var setPaused: @MainActor @Sendable (Bool) -> Void
    public var closePopover: @MainActor @Sendable () -> Void
    public var quitTelltale: @MainActor @Sendable () -> Void
    public static let noop: AppCommands
}
public struct UnitPreferences: Sendable, Codable, Equatable {
    public enum Temperature: String, Sendable, Codable, CaseIterable { case celsius, fahrenheit }
    public enum NetworkRate: String, Sendable, Codable, CaseIterable { case bytes, bits }
    public var temperature: Temperature = .celsius, networkRate: NetworkRate = .bytes
}
public struct PopoverLayout: Sendable, Codable, Equatable {   // edited in Settings (ruling)
    public var order: [Category] = Category.allCases, hidden: Set<Category> = []
}
```

SwiftUI environment (`MonitorUIKit/Environment/EnvironmentValues+Telltale.swift`, `@Entry`): `processActions`, `appCommands`, `unitPreferences`, `popoverLayout`, `historyProvider: any HistoryProvider` (default `EmptyHistoryProvider()` from MonitorModel), `isSnapshot`, `now: Date?`. Observables via `.environment(_:)`: `LiveModel`, `NavigationModel`.

```swift
@MainActor @Observable public final class NavigationModel {   // MonitorScreens/Shell (W4)
    public var page: DashboardPage = .overview
    public var range: HistoryRange = .live
    public var historyRange: HistoryRange = .day
    public var processesMode: ProcessesMode = .apps
    public var selection: ProcessSelection?
    public var historyScrub: Date?
    public enum ProcessesMode: String, Sendable { case apps, processes }
    public enum ProcessSelection: Hashable, Sendable { case app(AppKey), process(ProcessID) }
}
```

### 5.11 Runtime & mocks

```swift
// MonitorRuntime
public enum RuntimeMode: Sendable, Equatable { case live, mock(MockScenario) }
@MainActor public protocol RuntimePipeline: AnyObject {
    var live: LiveModel { get }; var history: any HistoryProvider { get }
    func start(); func setVisibility(_ v: UIVisibility); func setPaused(_ p: Bool)
    func systemWillSleep(); func systemDidWake(); func shutdown() async
}
@MainActor public final class TelltaleRuntime {        // façade (W0 writes; W7 owns); dispatches to:
    public static func make(mode: RuntimeMode, dataDirectory: URL, disabledSensors: Set<SensorID>,
                            crashSensor: SensorID? = nil) -> TelltaleRuntime   // crashSensor: DEBUG canary drill
    public var live: LiveModel { get }; public var history: any HistoryProvider { get }
    public func start(); public func setVisibility(_ v: UIVisibility); public func setPaused(_ p: Bool)
    public func systemWillSleep(); public func systemDidWake(); public func shutdown() async
}
// LivePipeline.swift (W7): engine + SensorFactory.live + HistoryStore.  MockPipeline.swift (Wm): MockDataProvider + MockHistoryProvider.
// Launch args / env (App/Composition/AppEnvironment.swift):
//   --mock <scenario> | TELLTALE_MOCK=<scenario>;  --open-dashboard <page>;  --open-popover;  --crash-sensor <id> (DEBUG)
//   TELLTALE_DATA_DIR=<dir>;  TELLTALE_DISABLE_SENSORS=coalitions,soc,…  (also UserDefaults "DisabledSensors")

// MonitorMocks (W0b: compiling stubs returning SystemFrame.empty-based frames; Wm: real data for every scenario incl. .calm)
public enum MockScenario: String, CaseIterable, Sendable, Codable {
    case calm, thermalFair, thermalCritical, memoryWarning, memoryCritical, runaway
    case collecting, sensorsUnavailable, paused
    case restricted       // many .restricted/.coalition rows, rss memory, synthetic coalition rows
}
public struct MockDataProvider: Sendable {
    public init(scenario: MockScenario, seed: UInt64 = 42, start: Date = MockDataProvider.referenceDate)
    public static let referenceDate: Date               // Thu 24 Sep 2026 14:32 local
    public var device: DeviceInfo { get }
    public func frame(at tick: Int) -> SystemFrame
    public func frames(interval: Duration) -> AsyncStream<SystemFrame>
    public func history() -> MockHistoryProvider
    public func processActions(log: ActionLog) -> ProcessActions
}
public final class MockHistoryProvider: HistoryProvider
public final class ActionLog: @unchecked Sendable        // lock-protected; @unchecked allowed only in MonitorMocks
```

`@MainActor static func LiveModel.mock(_ scenario: MockScenario, ticks: Int = 60) -> LiveModel` lives in `MonitorScreens/Shell/ScreenCatalog.swift` (W4).

### 5.12 UI kit API (`MonitorUIKit`, W3; names = DESIGN.md §2; all members `public`)

W0 writes compiling placeholders with exactly these signatures; W3 implements visuals per DESIGN.md.

```swift
enum TTColor { static func category(_ c: Category) -> Color; static func level(_ l: AlertLevel) -> Color
               /* + every DESIGN §1.1 token as static let */ }
enum TTFont { /* DESIGN §1.2 styles as static let: largeValue, sectionTitle, body13, body12, caption, captionMedium, micro … */ }
enum TTSpace, TTRadius { /* DESIGN §1.3 */ }

enum TTFormat {   // DESIGN §5 formatting rules; pure; nil → "—"
    static func percent(_ fraction: Double?, digits: Int = 0) -> String
    static func cpuPercent(_ p: Double?) -> String
    static func bytes(_ b: UInt64?) -> String
    static func rate(_ bps: Double?, units: UnitPreferences) -> String
    static func temperature(_ c: Double?, units: UnitPreferences) -> String
    static func watts(_ w: Double?, digits: Int = 1) -> String
    static func frequency(_ mhz: Double?) -> String
    static func duration(_ d: Duration?) -> String
    static func cpuTime(_ ns: UInt64?) -> String
    static func count(_ n: Int?) -> String
    static func rpm(_ r: Double?) -> String
}

/// One signature everywhere (§6): nil text → "—" + tooltip; estimated → DESIGN "estimated" style + tooltip.
struct MetricValue: View { init(_ text: String?, unavailableReason: String? = nil, estimated: Bool = false, font: Font = TTFont.body13) }

struct TTCard<Content: View>: View { init(padding: CGFloat? = nil, @ViewBuilder content: () -> Content) }
struct TTCardHeader<Trailing: View>: View { init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing) }
struct TTStatStrip: View { struct Item: Identifiable { var id: String; var label: String; var value: String?; var unit: String?; var detail: String?; var tint: Color?; var unavailableReason: String? }
                           init(_ items: [Item]) }
struct TTMetricTile: View { init(category: Category, value: String?, unit: String?, detail: String?, points: [SeriesPoint], unavailableReason: String?) }
struct TTAreaChart: View { init(_ points: [SeriesPoint], color: Color, yDomain: ClosedRange<Double>, fillOpacity: Double = 1, lineOnly: Bool = false) }  // Canvas; gap rule
struct TTTimelineRow: View { init(label: String, value: String?, points: [SeriesPoint], color: Color, yDomain: ClosedRange<Double>) }
struct TTCoreBars: View { init(cores: [CoreUsage], kind: CoreKind, color: Color) }
struct TTStackedArea: View { init(_ series: [ChartSeries], yDomain: ClosedRange<Double>) }
struct TTMirroredChart: View { init(up: ChartSeries, down: ChartSeries, upScale: Double, downScale: Double) }
struct TTLineChart: View { init(_ series: [ChartSeries], yDomain: ClosedRange<Double>, yFormat: @escaping (Double) -> String) }   // Swift Charts
struct TTDualChart: View { init(solid: ChartSeries, dashed: ChartSeries, yDomain: ClosedRange<Double>) }
struct ChartSeries: Identifiable { var id: String; var label: String; var color: Color; var points: [SeriesPoint] }
struct TTLegend: View { init(_ series: [ChartSeries]) }
struct TTTimeAxis: View { init(range: HistoryRange, end: Date) }            // Live: "60 s ago · 45 s · 30 s · 15 s · now"
struct TTSegmented<T: Hashable>: View { init(selection: Binding<T>, options: [(T, String)], compact: Bool = false) }
struct TTBadge: View { init(_ text: String, level: AlertLevel? = nil) }
struct TTProgressBar: View { init(value: Double?, tint: Color, thresholds: [(Double, AlertLevel)] = []) }
struct TTFanGauge: View { init(fan: FanSnapshot) }
struct TTKeyValueList: View { init(_ rows: [(String, String?)]) }
struct TTAppTile: View { init(identity: AppIdentity?, name: String, size: CGFloat = 20) }   // icon, else letter tile
struct TTTable<Row: Identifiable & Equatable>: View {                                       // LazyVStack, not NSTableView
    struct Column: Identifiable { var id: String; var title: String; var width: ColumnWidth; var alignment: HorizontalAlignment
                                  var sortKey: ((Row) -> Double?)?; var cell: (Row) -> AnyView }
    enum ColumnWidth { case flexible(min: CGFloat), fixed(CGFloat) }
    init(rows: [Row], columns: [Column], selection: Binding<Row.ID?>, sort: Binding<(column: String, descending: Bool)>,
         rowMenu: ((Row) -> AnyView)? = nil, children: ((Row) -> [Row])? = nil)
}
struct TTRowActionsMenu: View { init(target: ProcessTarget) }             // DESIGN §2.25; uses env processActions
struct TTSidebarItem: View { init(page: DashboardPage, value: String?, selected: Bool) }
struct TTPopoverRow: View { init(category: Category, subtitle: String?, value: String?, points: [SeriesPoint],
                                 compact: Bool, expanded: Binding<Bool>, topApps: [AppSample]) }
struct TTAlertBanner: View { init(title: String, message: String, level: AlertLevel, actions: [BannerAction]) }
struct BannerAction: Identifiable { var id: String; var title: String; var role: ButtonRole?; var perform: @MainActor () -> Void }
struct TTConfirmDialog: View { init(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) }
struct TTSearchField: View { init(text: Binding<String>, prompt: String) }
struct TTEmptyState: View { init(_ kind: Kind); enum Kind { case collecting(since: Date?), unavailable(String), empty(String), paused } }
struct TTToast: View { init(_ text: String, undo: (() -> Void)? = nil) }
struct PageScroll<Content: View>: View { init(@ViewBuilder _ content: () -> Content) }   // plain VStack when isSnapshot

enum TreemapLayout {        // DESIGN §2.28: squarified, sorted desc, "other" laid out last (bottom-right)
    static func squarify(_ values: [Double], otherIndex: Int?, in rect: CGRect) -> [CGRect]   // results in input order
    static func worstAspectRatio(_ rects: [CGRect]) -> Double
}
struct TTTreemap: View { init(_ shares: [AppShare], metric: AppMetric, animated: Bool, onSelect: ((AppKey) -> Void)? = nil) }
struct TTStatusGlyph: View { init(state: AlertState, size: CGFloat = 16, template: Bool) }
@MainActor enum StatusGlyphRenderer { static func image(for state: AlertState, pointSize: CGFloat = 18) -> NSImage }

@MainActor enum SnapshotRenderer {                    // MonitorUIKit (no Testing import; used by telltale-render too)
    enum Path: Sendable { case imageRenderer, hosting }
    static func render<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2, path: Path = .hosting) -> CGImage?
    static func imageRenderer<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> CGImage?   // pure SwiftUI only
    static func hosting<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> CGImage?         // offscreen NSWindow
    static func writePNG(_ image: CGImage, to url: URL) throws
}

// MonitorSnapshotTesting (test-support target; imports Testing; linked only by test targets)
@MainActor func assertSnapshot<V: View>(_ view: V, size: CGSize, named: String, path: SnapshotRenderer.Path = .hosting,
                                        tolerance: Double = 0.005, sourceLocation: SourceLocation = #_sourceLocation)
```

### 5.13 App shell decisions (W4)

- `main.swift` + `AppDelegate` (AppKit lifecycle), `.accessory` activation policy (+ `LSUIElement`).
- Status item: button image from `StatusGlyphRenderer`; re-armed `withObservationTracking` on `live.alert`; dimmed when paused; one pulse per `pulseToken` change.
- Popover: **borderless non-activating `NSPanel`** (design: 360 pt dark rounded panel, no arrow). Closes on outside click / Esc / status click. Hosting view created on open, released on close.
- Dashboard: `NSWindow` 1280×860 (min 1040×700), `.fullSizeContentView`, transparent titlebar, `.darkAqua`, released on close; occlusion/miniaturize → `VisibilityTracker`.
- Settings window: launch at login (`SMAppService.mainApp`), units, popover row order/hide, re-enable crashed/disabled sensors.
- `PowerEvents`: `NSWorkspace` will-sleep/did-wake → runtime.
- Termination: `.terminateLater` + `await runtime.shutdown()` (§4).
- `ProcessActionsLive`: `NSRunningApplication.terminate()/forceTerminate()`, `kill(SIGTERM/SIGKILL)`; `canControl` = all pids owned by `getuid()` and not synthetic; Reveal via `activateFileViewerSelecting`; Activity Monitor via `openApplication(at:)`; eject via `unmountAndEjectDevice(at:)`. No "Sample" action (ruling).

---

## 6. Errors & unavailable data

1. **Sensor**: `prepare()`/`sample()` throw `SensorError`. Missing weak symbol (`tt_*_available()` false) or versioned-struct mismatch → `.unavailable`. Coalition usage struct check: `_Static_assert(sizeof(struct coalition_resource_usage) == <findings size>)` in `Coalition.h`; at `prepare()`, call once on our own coalition with a buffer of `sizeof + 64` bytes pre-filled with sentinel `0xA5` and pass `sizeof` as the size: (a) every byte past `sizeof` must still be `0xA5` (kernel respected our size), (b) the last 8-byte field of our struct must no longer be all-`0xA5` (kernel's struct is at least as long as ours, so the prefix we read is real), (c) `cpu_time` > 0. Any failure → `.unavailable("coalition struct layout changed")`. errno failures → `SensorError.fromErrno(context)`. Async waits ≤ 250 ms → `.timeout`. Validate CF types and C buffer bounds; never crash on bad data.
2. **SensorSlot**:
   - `.transient`/`.timeout`/`.posix`: `.failed(err, last:, capturedNs:)`; last reading reused ≤ 2 intervals, then values `nil`; 3 consecutive failures → `.degraded`, backoff 2 s → 60 s.
   - `.unavailable`/`.permissionDenied`: status `.unavailable(reason)`, `invalidate()`, retry `prepare()` every 5 min.
   - Crash canary: marker in UserDefaults before first `prepare()`/`sample()` per launch, cleared after success; marker present at launch → `.disabled("Disabled after a crash")`; Settings "Re-enable sensors" clears it.
   - Kill switch: `TELLTALE_DISABLE_SENSORS` / defaults `DisabledSensors` → `UnavailableSensor`.
3. **Assembly**: missing values → snapshot fields `nil`; `frame.sensorHealth` carries reasons; restricted processes per §5.5.
4. **UI**: every metric renders through `MetricValue(text, unavailableReason:, estimated:)` (§5.12) with the reason from `unavailableReason(…)` (§5.5). Whole-panel absence → `TTEmptyState` (no battery, SMART status-only, approximate thermal map shown as a caption).
5. **States**: `LivePhase.collecting` until the first frame with rates; History: `coverage()` shorter than range → partial-history treatment (DESIGN "Partial history"); `nil` → empty.
6. **Store**: open failure → in-memory store + History banner "History unavailable"; write failure → drop batch, `os_log` fault; newer `user_version` → move file aside, start fresh.
7. **Actions**: `canControl == false` → disabled items; failures → `TTToast`.

Logging: `os.Logger(subsystem: "dev.telltale", category: <module>)`; `print` only in CLIs.

---

## 7. Performance design (advisory: UI closed < 1 % of one core avg, < 80 MB RSS)

Background tick budget at 5 s: ≤ 25 ms (hard ceiling 50 ms).

| Step | Cost | Notes |
|---|---|---|
| sysctl `KERN_PROC_ALL` | est. < 1 ms | retained buffer (~920 × 648 B); only list fields copied |
| rusage v6 on ~590 permitted pids | est. 3–6 ms | stack `rusage_info_v6`; name/path/responsible only for **new** `ProcessID`s |
| coalitions | 1.3–2.1 ms | membership: `PROC_PIDCOALITIONINFO` only for new pids (exited pids dropped); full pass (0.35 ms) at start only |
| IOReport | ~2 ms (measured) | subscription once; only subscribed channels |
| AGX walk | ~2 ms (measured) | per-client deltas |
| SMC (fans + catalog keys + PSTR/PDTR) | < 1 ms | key list from cache; full sweep (0.45–0.57 s) once, off-queue, cached in `~/Library/Caches/dev.telltale/smc-keys-<hwModel>-<osBuild>.json` |
| HID raw temps | 65–80 ms | **never in background**; 2 s only on Thermals with `.rawTemperatures` |
| NStat | 21–28 ms per query (measured) | off the sampler queue (box queue); background every 10 s, interactive every tick; `sample()` returns the last completed query and starts the next |
| host/vm/ifaddrs/disk stats | < 1 ms | `vm_deallocate` processor info each tick |
| `ps` (rootMemory) | ~20 ms, off-queue | only with `.processTable` or `.memoryAlert`, 30 s |
| assemble + attribution + alerts + record | 1–3 ms | dictionaries `reserveCapacity`, `removeAll(keepingCapacity:)` |

Estimated background CPU per 5 s ≈ 12–20 ms on the sampler queue + ~12 ms amortized NStat (25 ms / 10 s) ≈ 25–32 ms ≈ 0.5–0.65 % of a core. Interactive (1 s) ≈ 40–50 ms/s ≈ 4–5 % while UI is open (advisory).

Allocation avoidance: scratch buffers kept across ticks; strings interned per `ProcessID`; `MetricVector` instead of dictionaries; no `Date`/formatters in hot loops; CF objects released within the tick; frames are CoW.

Background cuts: no per-core array, no HID, no raw SMC list, no connection endpoints/reverse DNS, Wi-Fi 30 s, volumes 60 s, no SMART, no `ps` unless memory alert; `LiveModel.isPresenting == false` ⇒ only `alert`/`phase`/ring buffers change; popover/dashboard hosting views torn down on close.

Timers: `Task.sleep(until:tolerance:)` with 10 % tolerance. App Nap: W7 measures the background interval; if median > 6 s, W4 adds a `ProcessInfo.beginActivity` assertion (verified with `pmset -g assertions` not blocking idle sleep).

UI redraw limits:
- ≤ one `LiveModel.apply` per tick; properties assigned only when changed; per-category version counters so a CPU page doesn't re-evaluate on network changes.
- No `TimelineView`; chart animations off, **except** the treemap's DESIGN-mandated 0.25 s tile transition once per tick (skipped while scrubbing).
- Sparklines/area charts via `Canvas`; Swift Charts only for large page charts; points bounded by `displayBucket` (≤ 240/series) or 60–300 live points.
- Tables: stable ids, `Equatable` rows, sort/filter once per frame in `ProcessTableModel`, `LazyVStack`.
- App icons in `NSCache`; status glyph images cached per `(arcs, level, paused)`.
- Occluded/miniaturized dashboard ⇒ background mode.

Memory: GRDB cache 2 MB; ring buffers ≈ 0.2 MB; per-app live series for top 64 apps ≈ 1 MB; frame ≈ 0.3 MB. Target idle RSS 45–60 MB.

Measurement (W7): `scripts/perf.sh 10` (UI closed), `scripts/perf.sh 2 --interactive`, `telltale-probe --bench --ticks 60` → `docs/perf/<date>-<cp>.md`.

---

## 8. Testing strategy

| Layer | Kind | Suite(s) |
|---|---|---|
| Model | Codable round-trip; `MetricVector` by-rawValue coding; `RawTick` missing keys → `.notRequested`; `unavailableReason` table | `MonitorModelTests` |
| Live model | observation granularity, change-only assignment, presenting gate | `MonitorLiveTests` |
| Engine | TDD: rates (capturedNs semantics), CPU ticks, grouping, **coalition attribution (no double counting, scoped to coalitions with ≥ 1 restricted member: there Σ member CPU/disk == Δcoalition; all-visible coalitions untouched and produce no synthetic rows)**, energy attributor (N6 order; fallback mode: no coalition residual, SoC share only fills nils), session accumulator, assembly, records, alerts, events, slots, loop wake-up | `MonitorEngineTests` |
| Store | TDD on `.inMemory` + injected clock; ALTER-ADD-COLUMN; rollups; CSV golden | `MonitorStoreTests` |
| UI kit | `TTFormat`, `TreemapLayout`, chart gap segmentation, glyph; component snapshots | `MonitorUIKitTests` |
| Screens | snapshots per mock scenario incl. `restricted` | `MonitorScreensTests` |
| Sensor parse | pure decoders on captured dumps: IOReport channel map, `PStateCatalog`, SMC decode **byte order per key family** (fan/temp ints big-endian, battery `B0**`/`CH**` ints little-endian, `flt ` little-endian; values from `docs/findings/smc.md`, e.g. `B0CT` → 1855), `TemperatureCatalog` per hw.model, AGX creator parsing, NStat dict → `FlowCounter`, coalition struct decode, `ps` output parse | `MonitorSensorsTests/*ParseTests` |
| Sensor FFI | smoke on this Mac, gated `TELLTALE_HW_TESTS=1` | `*SmokeTests` |
| Runtime | fixture sensors + in-memory store end to end; mock pipeline | `MonitorRuntimeTests` |
| Mocks | determinism per scenario | `MonitorMocksTests` |

Framework: Swift Testing; `@MainActor` suites for view tests. Command: `scripts/test.sh <Suite>`.

Fixtures: `telltale-probe --record Tests/MonitorEngineTests/Fixtures/recorded/<name>.json --ticks 20 --interval 1` (idle, 8× `yes`, many-helper app, sleep/wake). Until they exist W1 uses builders in `Tests/MonitorEngineTests/Support/`. No sudo-based reference checks (ruling); sensors are verified by plausibility (idle vs. `yes`/Metal load) and against `top`, `ps`, `vm_stat`, `nettop`, `iostat`, `ioreg`.

Snapshots (W3; `assertSnapshot` lives in the test-only `MonitorSnapshotTesting` target so the app never links Testing): goldens `Tests/<Target>/__Snapshots__/<name>.png`; record with `TELLTALE_RECORD=1`; failures → `.build/snapshot-failures/<name>.{actual,golden,diff}.png`; compare = fraction of pixels with any channel Δ > 8/255 (default 0.5 %). Determinism: `isSnapshot = true`, `now = MockDataProvider.referenceDate`, `en_US`, `Europe/London`, dark, scale 2, `frame(at: 60)`.

Design verification:
1. Reference: `docs/design/reference/<Artboard>@2x.png` (design agent).
2. Ours: `scripts/render.sh <screen> <scenario>` (hosting path, artboard size, @2x). `ScreenCatalog`: `popover`→MenuBar, `popover-alert`→MenuBarAlert (thermalFair), `status-icons`→StatusIcon, `overview`→Main, `cpu`, `gpu`, `memory`, `network`, `thermals`, `power`, `disk`, `processes`, `history`.
3. Compare: the owner views both PNGs and writes a checklist in the PR (grid/spacing, typography, tokens, copy, formats, states); `telltale-render --compare <ref>` makes side-by-side + overlay. Structural/token fidelity, not pixel equality.
4. After sign-off the render becomes the regression golden.

Test running rule (user): rerun only failing tests + suites whose sources changed; full `swift test` only at integration checkpoints (shared-infrastructure merge) or on request — say which.

---

## 9. Change control

- W0 (W0a + W0b) owns `MonitorModel/**` (incl. `Sensors/BuiltinSensors.swift`), `Package.swift`, `.gitignore`, `scripts/{gen,build,test,ci}.sh`, `CPrivate/shim.c`, `MonitorSensors/LiveSensorFactory.swift`, `MonitorRuntime/TelltaleRuntime.swift` until merge; afterwards the integrator (W7), except `MonitorRuntime/TelltaleRuntime.swift` → W7.
- Model changes: `docs/icr/<NNN>-<stream>-<slug>.md` (what, why, Swift diff, affected streams). Integrator lands ICRs as small `model:` commits on `dev`; streams rebase. Meanwhile the stream uses a local extension in its own target.
- Allowed without ICR: extensions in the stream's own target; new files in owned directories; `MonitorSensors/Support/<Stream>+<Topic>.swift` helpers (one prefix per stream, e.g. `W6a+KinfoProc.swift`); fixtures.
- Compatibility: additive only (optional fields with defaults, enum cases only where no exhaustive `switch` exists outside the owner, protocol requirements only with default implementations). New `HistoryMetric`/`AppMetric` cases need no store migration (ALTER-ADD at open).

---

## 10. Rulings applied (2026-09-24, architecture review)

- libsysmon: unusable (sysmond requires the `com.apple.sysmond.client` entitlement; AMFI kills self-signed binaries claiming it). Removed. Root processes come from sysctl + resource coalitions + `ps` RSS.
- Energy: rusage v6 `ri_energy_nj` for own-uid pids → coalition energy residual for restricted pids (only in coalitions with a restricted member; off when v6 is unavailable) → SoC share fills remaining nils.
- Coalition `gpu_time` is not used (unknown unit); AGX is the only per-process GPU source. `ri_billed_energy` is dead (always 0). Open gap from findings: whether `ri_energy_nj` includes GPU energy — W6a checks with a Metal load; if not, add a `gpuW × gpu share` term via ICR.
- Coalition residual → a named row per coalition (leader `p_comm`), else "System".
- `ps` runs only while a process table is visible, or in background while a memory alert is active.
- HID temps = raw list only; groups and thermal background data from SMC via a per-`hw.model` catalog.
- History keeps full resolution for 24 h; the copy changes (DESIGN.md owns the wording).
- Runaway app = ≥ 100 % CPU sustained 5 min → elevated.
- User-owned non-bundle executables get their own group.
- Processes "Sample" button dropped. Compressed/Private/Ports columns removed.
- Popover row reorder/hide lives in Settings. Paused → dimmed glyph.
- Bundle id prefix `dev.telltale`; install to `~/Applications`.
- Reference PNGs come from the design agent (`docs/design/reference/`). No sudo verification.
