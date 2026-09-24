# Telltale — Architecture

Status: binding for M1+. Inputs: `SPEC.md` (incl. Design reference + Rulings), M0 spike plan, `docs/design/artboards/*.dc.html`, `docs/design/DESIGN.md` (tokens/components, written separately), `docs/findings/*.md` (M0 results, pending).
Work breakdown: `docs/superpowers/plans/2026-09-24-parallel-build-plan.md`.

Contents: 1 Build system · 2 Module layout · 3 Data flow · 4 Concurrency · 5 Interfaces (locked) · 6 Errors/unavailable · 7 Performance · 8 Testing + design verification · 9 Change control

---

## 1. Build system

**Decision: XcodeGen (`project.yml`) for the thin app target + local SwiftPM package `MonitorCore` holding ~95% of the code, UI included.**

- `xcodegen` 2.46.0 is installed (`/opt/homebrew/bin/xcodegen`). `Telltale.xcodeproj` is **generated and gitignored**: no `.pbxproj` merge conflicts across worktrees, and new files under `App/Sources/**` are picked up by glob, so no stream edits the project file.
- A real app target (not SwiftPM + hand-assembled bundle) because we need: `LSUIElement`, ad-hoc code signing that `SMAppService.mainApp` accepts, an asset catalog (app icon), and linking the package's private-framework flags into a proper bundle. Xcode does all of this; a bundling script would re-implement it.
- UI lives in the package (`MonitorUIKit`, `MonitorScreens`), not in `App/`. Reason: `swift build`/`swift test` compile and snapshot-test every view headlessly and fast, per worktree, without `xcodebuild`. `App/` is only the AppKit shell + composition root. (Deviation from `SPEC.md` "Structure": App/ stays "UI only" in the sense of shell; views move into the package for testability.)
- Swift 6 language mode for all targets except `CPrivate` (C).
- CLI only, no Xcode clicks:

| Command | What |
|---|---|
| `scripts/gen.sh` | `xcodegen generate --spec project.yml --quiet` |
| `scripts/build.sh` | gen + `xcodebuild -project Telltale.xcodeproj -scheme Telltale -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build`, prints only `error:`/`warning:`/`BUILD` lines + app path |
| `scripts/run.sh [--mock <scenario>]` | kills running Telltale, `open -n .build/xcode/Build/Products/Debug/Telltale.app --args …` with `TELLTALE_DATA_DIR=$PWD/.build/data` |
| `scripts/test.sh <filter…>` | `cd MonitorCore && swift test --filter <filter> 2>&1 \| tail -25` (one run per filter) |
| `scripts/ci.sh <suites…>` | pre-merge gate: `swift build` (all targets) + `scripts/build.sh` + `scripts/test.sh` for the given suites |
| `scripts/render.sh <screen> <scenario>` | `swift run telltale-render …` → PNG in `.build/renders/` |
| `scripts/probe.sh [args]` | `swift run -c release telltale-probe …` (live sensors, costs, fixture recording) |
| `scripts/perf.sh [minutes]` | launches app live, samples `ps -o %cpu=,rss=` every 5 s, prints avg CPU % and max RSS |
| `scripts/install.sh` | release build → `~/Applications/Telltale.app` (stable path for launch at login) |

`project.yml` essentials (W0 writes; W4 owns afterwards):

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
        products: [MonitorRuntime, MonitorScreens, MonitorUIKit]
```

No sandbox, no entitlements file. Private links (`IOReport`, `sysmon`, `-framework NetworkStatistics`) are declared once on `CPrivate` via `linkerSettings` (same `privateLinks` as `Spikes/Package.swift`); `unsafeFlags` is allowed because the package is local. W0 acceptance proves this links in `xcodebuild`.

---

## 2. Module layout

```
system-monitor/
  project.yml                      XcodeGen spec (Telltale.xcodeproj is generated, gitignored)
  scripts/                         gen, build, run, test, render, probe, perf, install
  App/
    Info.plist
    Resources/Assets.xcassets      app icon
    Sources/
      main.swift                   NSApplication bootstrap (no SwiftUI App lifecycle)
      AppDelegate.swift
      Composition/AppEnvironment.swift        runtime mode (live/mock), settings, wiring
      StatusItem/StatusItemController.swift   NSStatusItem + glyph + pulse
      Popover/PopoverPanelController.swift    borderless NSPanel under status item
      Dashboard/DashboardWindowController.swift
      Settings/SettingsWindowController.swift, SettingsStore.swift
      Services/ProcessActionsLive.swift, LaunchAtLogin.swift, VisibilityTracker.swift, PowerEvents.swift
  MonitorCore/
    Package.swift
    Sources/
      CPrivate/                    C: private API decls + SMC shim (ported from Spikes/)
        include/{Responsibility,Sysmon,IOReport,HIDPrivate,SMC,NStat}.h
        shim.c, smc.c
      MonitorModel/                pure Foundation; ALL shared types/protocols (locked after W0)
        Basics/  Identifiers.swift Time.swift Metrics.swift Units.swift
        Readings/ Process.swift HostCPU.swift Memory.swift SoC.swift GPUClients.swift Temperature.swift
                  SMC.swift Network.swift Disk.swift Power.swift Device.swift
        Snapshots/ SystemFrame.swift CPU.swift GPU.swift Memory.swift Network.swift Thermals.swift
                   Power.swift Disk.swift ProcessSample.swift AppSample.swift Connection.swift
        Sensors/  Sensor.swift SensorSuite.swift RawTick.swift Sampling.swift
        Alerts/   Alert.swift HistoryEvent.swift
        History/  HistoryProvider.swift HistoryRecord.swift
        Services/ ProcessActions.swift AppCommands.swift Preferences.swift Navigation.swift
      MonitorEngine/               sampling loop, rates, grouping, assembly, alerts, live model
        Rates/ RateCalculator.swift CPUTicks.swift
        Grouping/ AppResolver.swift AppGrouper.swift
        Assembly/ FrameAssembler.swift ProcessAssembler.swift SystemAssembler.swift
        Records/ RecordBuilder.swift
        Alerts/ AlertEngine.swift EventDetector.swift
        Live/ RingBuffer.swift LiveHistory.swift LiveModel.swift
        Sampling/ SamplingEngine.swift SensorSlot.swift CrashCanary.swift
      MonitorSensors/              one subdir per source; each type replaces a W0 stub
        Process/ RusageProcessSensor.swift SysmonProcessSensor.swift FallbackProcessSensor.swift
        Host/ HostCPUSensor.swift MemorySensor.swift DeviceInfoSensor.swift SleepAssertionSensor.swift
        SoC/ IOReportSensor.swift GPUClientsSensor.swift
        Thermal/ HIDTemperatureSensor.swift SMCSensor.swift ThermalStateSensor.swift TemperatureCatalog.swift
        Power/ BatterySensor.swift
        Network/ NStatSensor.swift InterfaceSensor.swift WiFiSensor.swift LatencyProbe.swift ReverseDNS.swift
        Disk/ DiskIOSensor.swift VolumeSensor.swift SMARTSensor.swift
        Support/ UnavailableSensor.swift Mach.swift CFHelpers.swift
        LiveSensorFactory.swift    references every adapter type by name (written once by W0)
      MonitorStore/                GRDB: schema, writer, rollups, queries, CSV
        Database.swift Schema.swift HistoryStore.swift Rollup.swift Retention.swift Queries.swift CSVExporter.swift
      MonitorUIKit/                tokens, formatters, components, charts, treemap, glyph, snapshot harness
        Tokens/ Colors.swift Typography.swift Spacing.swift
        Format/ Fmt.swift
        Components/ Panel.swift StatTile.swift MetricValue.swift Sparkline.swift StackedBar.swift CoreGrid.swift
                    PressureScale.swift RangePicker.swift DataTable.swift AppIcon.swift AlertBanner.swift
                    EmptyState.swift ConfirmSheet.swift Toast.swift PageScroll.swift
        Charts/ LiveChart.swift HistoryChart.swift ChartSegments.swift
        Treemap/ TreemapLayout.swift TreemapView.swift
        Glyph/ StatusGlyph.swift StatusGlyphRenderer.swift
        Environment/ EnvironmentValues+Telltale.swift
        Snapshot/ SnapshotRenderer.swift SnapshotAssert.swift
      MonitorScreens/              popover content, dashboard shell + pages
        Shell/ DashboardRoot.swift Sidebar.swift DeviceHeader.swift PageHeader.swift NavigationModel.swift
               SettingsView.swift ScreenCatalog.swift
        Popover/ PopoverRoot.swift PopoverRow.swift TopConsumer.swift
        Pages/ OverviewPage.swift CPUPage.swift GPUPage.swift MemoryPage.swift NetworkPage.swift
               ThermalsPage.swift PowerPage.swift DiskPage.swift
               Processes/ ProcessesPage.swift ProcessTableModel.swift AppInspector.swift
               History/ HistoryPage.swift HistoryModel.swift TimeTravelTreemap.swift
      MonitorMocks/                MockDataProvider, MockHistoryProvider, scenarios, fixture loaders
      MonitorRuntime/              composition: live (engine+sensors+store) or mock; UI visibility → mode/demand
        TelltaleRuntime.swift LivePipeline.swift MockPipeline.swift
      telltale-render/main.swift   CLI: render any ScreenCatalog entry × scenario to PNG
      telltale-probe/main.swift    CLI: run live sensors headless; costs; record RawTick fixtures
    Tests/
      MonitorEngineTests/ (+ Fixtures/*.json)   MonitorStoreTests/   MonitorUIKitTests/ (+ __Snapshots__)
      MonitorScreensTests/ (+ __Snapshots__)    MonitorSensorsTests/ (parse tests + HW smoke)   MonitorRuntimeTests/
  Spikes/                          M0 (throwaway, reference source for W6)
  docs/ ARCHITECTURE.md  design/{artboards,reference,DESIGN.md}  findings/  icr/  superpowers/plans/
```

Target graph (Package.swift, written once by W0):

```
CPrivate          (C)                              linkerSettings: privateLinks
MonitorModel      → —                              Foundation only
MonitorEngine     → MonitorModel                   + Observation
MonitorSensors    → MonitorModel, CPrivate         + IOKit, CoreWLAN, SystemConfiguration
MonitorStore      → MonitorModel, GRDB (≥ 7.0)
MonitorUIKit      → MonitorModel                   + SwiftUI, Charts, AppKit
MonitorMocks      → MonitorModel
MonitorScreens    → MonitorModel, MonitorEngine, MonitorUIKit, MonitorMocks
MonitorRuntime    → MonitorModel, MonitorEngine, MonitorSensors, MonitorStore, MonitorMocks
telltale-render   → MonitorScreens, MonitorUIKit, MonitorMocks, MonitorEngine
telltale-probe    → MonitorRuntime
App (Xcode)       → MonitorRuntime, MonitorScreens, MonitorUIKit
```

Rule: UI targets never import `MonitorSensors`/`MonitorStore`; they see data only via `LiveModel` and `HistoryProvider`.

---

## 3. Data flow

```
 sensors (sync, on sampler queue)                                 MainActor
 ┌──────────────┐   SensorResult<R>   ┌────────────┐  SystemFrame  ┌──────────────┐  @Observable  ┌────────┐
 │ SensorSlot×18│ ──────────────────▶ │  RawTick   │ ────────────▶ │  LiveModel   │ ────────────▶ │ Views  │
 └──────────────┘  (cadence, cache,   └─────┬──────┘  AsyncStream  │ ring buffers │               └────────┘
        ▲           backoff, cost)          │ FrameAssembler       │ alert state  │──▶ StatusItemController
        │                                   ▼ (rates, grouping)    └──────────────┘
 SamplingEngine actor ──────────────▶ SystemFrame ──▶ AlertEngine ──▶ EventDetector
   (mode, demand, timer)                    │
                                            ▼ RecordBuilder (thresholds, "other")
                                      HistoryRecord + [HistoryEvent]
                                            │ AsyncStream (unbounded, tiny)
                                            ▼
                                      HistoryStore actor ── buffer ── flush 30 s ── GRDB DatabasePool (WAL)
                                            │                           rollup + retention every 5 min
                                            ▼
                         HistoryProvider (async reads) ◀── History page, range charts, treemap, CSV export
```

Per tick (`SamplingEngine.tick()`):
1. `ctx = SampleContext(now)`; for each slot due under current mode/demand: `slot.sample(ctx)` → `SensorResult<R>` (`fresh`/`cached`/`failed`/`unavailable`/`notRequested`).
2. Build `RawTick` (Codable; this is the fixture format).
3. `FrameAssembler.assemble(tick)` → `SystemFrame`: counter deltas via `RateCalculator`, CPU ticks → usage, PID → `AppKey` via `AppResolver` (cached), per-app sums via `AppGrouper`, temps grouped, per-app GPU/net/energy joined by PID.
4. `AlertEngine.update(frame)` → `AlertState` (+ transitions) written into the frame.
5. `EventDetector.update(frame)` → closed `HistoryEvent`s into the frame.
6. Yield frame to `liveFrames` (buffering newest 1). Yield `RecordBuilder.record(frame)` + events to `records` (only when not paused).
7. Sleep until next deadline (`Task.sleep(until:tolerance:)`).

Mode changes (`UIVisibility` from the shell): `background` (5 s), `interactive` (1 s), `paused` (no sampling, no records; emits `samplingPaused`/`samplingResumed` events; charts show the gap). Sleep/wake: engine resets baselines (`RateCalculator.reset()`), writes a `systemSleep` event; first post-wake frame has no rates (collecting).

---

## 4. Concurrency model (Swift 6 strict)

| Component | Isolation | Notes |
|---|---|---|
| `SamplingEngine` | `actor`, custom executor = `DispatchSerialQueue("dev.telltale.sampler", qos: .utility)` | Sensor calls block (IOKit, mach, CF) — they run on our queue, never on the cooperative pool. macOS 14 `DispatchSerialQueue` is a `SerialExecutor`. |
| Sensors (`Sensor` classes) | owned by the engine actor, **non-Sendable**, never escape | Created inside the actor via `SensorFactory.make` (`@Sendable () -> SensorSuite`). Hold C handles (IOReport sub, HID client, SMC conn). |
| Event-driven sensors (NStat, LatencyProbe, ReverseDNS) | own serial `DispatchQueue`; shared state behind `OSAllocatedUnfairLock` (macOS 13+; `Mutex` needs 15) | `sample()` just snapshots accumulated state under the lock. These classes are `@unchecked Sendable` with the lock documented — the only allowed `@unchecked` uses. |
| Snapshots, readings, records, events | `struct … : Sendable, Codable, Equatable` | Immutable values crossing isolation domains. Arrays are CoW: sending a frame is O(1). |
| `FrameAssembler`, `RateCalculator`, `AlertEngine`, `EventDetector`, `RecordBuilder` | plain structs, mutated only inside the engine actor | Pure; unit-tested without concurrency. |
| `HistoryStore` | `actor` wrapping GRDB `DatabasePool` (Sendable) | Writes: buffered, one transaction per flush via `try await pool.write`. Reads: `pool.read` concurrently (WAL). Blocking `flushSync()` only in `applicationWillTerminate`. |
| `LiveModel`, `NavigationModel`, `SettingsStore`, controllers, views | `@MainActor` (`@Observable` for models) | One consumer `Task { @MainActor in for await f in runtime.liveFrames { live.apply(f) } }`. |
| Service closures (`ProcessActions`, `AppCommands`) | `Sendable` structs of `@MainActor @Sendable` closures | Injected through SwiftUI environment. |

Bans: `nonisolated(unsafe)` (except C globals in `CPrivate` shims), `DispatchQueue.main.sync`, `MainActor.assumeIsolated` outside AppKit delegate callbacks, `Task.detached` without a stated reason.

---

## 5. Interfaces (locked after W0; change only via §9)

Conventions:
- Ratios `0...1` are `Double` named `…Fraction` or `usage`. **Exception:** process/app CPU and GPU are `cpuPercent`/`gpuPercent` in Activity-Monitor semantics (100 = one core / whole GPU), because the design shows "212.4%".
- Bytes `UInt64`; rates `Double` bytes/s; temps `Double` °C; power `Double` W; frequency `Double` MHz; CPU time `UInt64` ns; monotonic time `UInt64` ns from `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)`.
- `nil` = unavailable/unknown (renders "—" + tooltip). Never `0` for unknown.
- All public structs get an explicit `public init` with defaults for every field, so additive fields don't break call sites.

### 5.1 Identity & grouping (`MonitorModel/Basics/Identifiers.swift`)

```swift
public struct ProcessID: Hashable, Sendable, Codable {    // pid alone is reused; startTime disambiguates
    public var pid: Int32
    public var startTimeNs: UInt64                        // ri_proc_start_abstime → ns (0 if unknown)
}

public struct AppKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable { case app, process, system, other }
    public let kind: Kind
    public let id: String      // app: bundle id (fallback: bundle path); process: executable path; system: "system"; other: "other"
    public init(kind: Kind, id: String)
    public static let system: AppKey   // (.system, "system")
    public static let other: AppKey    // (.other, "other") — history rows below threshold
}

public struct AppIdentity: Hashable, Sendable, Codable {
    public var key: AppKey
    public var displayName: String     // "Final Cut Pro", "System", "node"
    public var bundlePath: String?     // for NSWorkspace icon, Reveal in Finder
}

public enum Category: String, CaseIterable, Sendable, Codable {   // popover rows + icon arcs subset
    case cpu, gpu, memory, network, thermals, power, disk
}
public enum IconArc: String, CaseIterable, Sendable, Codable { case cpu, gpu, memory, network, thermals }
```

Grouping rule (`AppGrouper`/`AppResolver`, W1):
1. `r = responsiblePID ?? pid`; path of `r` (cached per `ProcessID`).
2. Path contains `.app/` → outermost `.app` bundle → `AppKey(.app, bundleID ?? bundlePath)`, name = `CFBundleDisplayName ?? CFBundleName ?? bundle filename`.
3. Else if owned by current uid and path not under `/System/`, `/usr/`, `/sbin/`, `/bin/`, `/Library/Apple/` → `AppKey(.process, path)` (Homebrew services, node, etc.).
4. Else → `.system` ("System").
5. EPERM/restricted rows with unknown path → `.system`.

```swift
public protocol AppResolving: AnyObject {                   // MonitorEngine/Grouping/AppResolver.swift
    func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity
    func prune(keeping live: Set<ProcessID>)
}
public final class BundleAppResolver: AppResolving { public init(currentUID: uid_t = getuid()) }   // caches by ProcessID + bundle path
public final class FixtureAppResolver: AppResolving { public init(_ map: [Int32: AppIdentity]) }  // tests
```

### 5.2 Time, metrics, series (`Basics/Time.swift`, `Basics/Metrics.swift`)

```swift
public enum SamplingMode: String, Sendable, Codable { case background, interactive, paused
    public var interval: Duration? { get }   // 5 s, 1 s, nil
}

public struct SamplingDemand: OptionSet, Sendable, Codable, Hashable {   // extra detail only UI needs
    public let rawValue: UInt32
    public static let perCore, connections, rawTemperatures, wifi, smart, volumes, sleepAssertions: SamplingDemand
    public static let none: SamplingDemand = []
}

public struct UIVisibility: Sendable, Equatable {
    public var popoverOpen: Bool
    public var dashboardVisible: Bool          // visible && !occluded && !miniaturized
    public var page: DashboardPage?
    public var inspectedApp: AppKey?
    public var mode: SamplingMode { get }      // interactive if popoverOpen || dashboardVisible
    public var demand: SamplingDemand { get }  // derived from page (cpu→perCore, network→connections+wifi, thermals→rawTemperatures, disk→smart+volumes, power→sleepAssertions, processes/inspector→connections)
}

public enum HistoryRange: String, CaseIterable, Sendable, Codable {
    case live, hour, day, week, month          // Live / 1H / 24H / 7D / 30D
    public var duration: Duration? { get }     // nil for live
    public var label: String { get }           // "Live", "1H", "24H", "7D", "30D"
}

public enum HistoryMetric: String, CaseIterable, Sendable, Codable {  // one column each in system_* tables
    case cpuUsage, cpuUser, cpuSystem, cpuPCluster, cpuECluster, loadAvg1
    case gpuUsage, gpuFrequency
    case memUsed, memApp, memWired, memCompressed, memPressure, swapUsed
    case netRx, netTx, netLatency
    case diskRead, diskWrite, diskReadIOPS, diskWriteIOPS
    case socTemp, cpuPTemp, cpuETemp, gpuTemp, ssdTemp, batteryTemp, fan1RPM, fan2RPM
    case packageWatts, cpuWatts, gpuWatts, aneWatts, dramWatts, systemWatts, batteryPercent
    case thermalPressure                                         // 0 nominal … 3 critical
    public var index: Int { get }                                // stable position in MetricVector
}

public enum AppMetric: String, CaseIterable, Sendable, Codable {
    case cpu, gpu, memory, netRx, netTx, diskRead, diskWrite, energy
    public var index: Int { get }
}

public protocol MetricKey: CaseIterable, Hashable, Sendable, Codable { var index: Int { get } }
extension HistoryMetric: MetricKey {}
extension AppMetric: MetricKey {}

/// Fixed-size, allocation-free metric row backed by ContiguousArray<Double>. NaN = missing.
public struct MetricVector<Key: MetricKey>: Sendable, Codable, Equatable {
    public init()                                   // all NaN, count = Key.allCases.count
    public subscript(_ key: Key) -> Double? { get set }
}
public typealias SystemMetrics = MetricVector<HistoryMetric>
public typealias AppMetrics = MetricVector<AppMetric>

public struct SeriesPoint: Sendable, Codable, Equatable {
    public var time: Date
    public var value: Double?                       // nil = gap marker (chart breaks the line)
}
```

### 5.3 Raw readings (`MonitorModel/Readings/*`) — what sensors return

Sensors do FFI + source-specific decoding only (incl. name→group mappings learned in M0). No deltas except where the source itself is delta-based (IOReport).

```swift
public struct RawProcess: Sendable, Codable, Hashable {
    public var id: ProcessID
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var path: String?
    public var responsiblePID: Int32?               // responsibility_get_pid_responsible_for_pid, nil on failure
    public var cpuTimeNs: UInt64?                   // user+system, mach ticks converted
    public var footprint: UInt64?
    public var diskReadBytes: UInt64?, diskWriteBytes: UInt64?    // lifetime counters
    public var billedEnergyNJ: UInt64?
    public var threads: Int32?
    public var compressed: UInt64?, privateBytes: UInt64?, ports: Int32?   // libsysmon only
    public var restricted: Bool                     // EPERM: counters nil
}
public struct ProcessTableReading: Sendable, Codable {
    public enum Source: String, Sendable, Codable { case rusage, sysmon }
    public var source: Source
    public var processes: [RawProcess]
}

public enum CoreKind: String, Sendable, Codable { case performance, efficiency }
public struct CoreTicks: Sendable, Codable, Hashable { public var user, system, idle, nice: UInt64 }
public struct HostCPUReading: Sendable, Codable {
    public var cores: [CoreTicks]                   // cumulative, index = logical cpu
    public var coreKinds: [CoreKind]                // same indexing
    public var loadAverage: [Double]                // 1, 5, 15 min
}

public enum MemoryPressureLevel: Int, Sendable, Codable, Comparable { case normal = 1, warning = 2, critical = 4 }
public struct MemoryReading: Sendable, Codable {
    public var pageSize: UInt64, total: UInt64
    public var free, active, inactive, speculative, wired, purgeable, fileBacked, anonymous: UInt64
    public var compressorBytes: UInt64              // physical bytes held by compressor
    public var compressedOriginalBytes: UInt64?     // uncompressed size (ratio)
    public var pageins, pageouts, swapins, swapouts: UInt64   // cumulative
    public var swapTotal, swapUsed: UInt64
    public var swapFileCount: Int?
    public var pressureLevel: MemoryPressureLevel?
    public var pressureFraction: Double?            // design "Memory pressure 42%"; derivation from findings
}

public enum ClusterKind: String, Sendable, Codable { case performance, efficiency }
public struct ClusterResidency: Sendable, Codable, Hashable {
    public var name: String                         // "PCPU0", "ECPU" …
    public var kind: ClusterKind
    public var activeFraction: Double
    public var frequencyMHz: Double?, maxFrequencyMHz: Double?
}
public struct MediaEngineReading: Sendable, Codable, Hashable { public var name: String; public var activeFraction: Double }
public struct SoCPowerReading: Sendable, Codable {  // IOReport: already a delta over `interval`
    public var interval: Duration
    public var cpuWatts, gpuWatts, aneWatts, dramWatts: Double?
    public var clusters: [ClusterResidency]
    public var gpuActiveFraction: Double?, gpuFrequencyMHz: Double?, gpuMaxFrequencyMHz: Double?
    public var mediaEngines: [MediaEngineReading]   // empty if IOReport lacks them (ruling)
}

public struct GPUClientCounter: Sendable, Codable, Hashable { public var pid: Int32; public var gpuTimeNs: UInt64 }
public struct GPUClientsReading: Sendable, Codable {
    public var clients: [GPUClientCounter]          // cumulative accumulatedGPUTime per pid (summed across user clients)
    public var deviceUtilization: Double?           // AGX "Device Utilization %" / 100 (fallback for GPU total)
    public var inUseSystemMemory: UInt64?           // GPU page "GPU memory"
}

public enum TemperatureGroup: String, CaseIterable, Sendable, Codable {
    case cpuPerformance, cpuEfficiency, gpu, soc, ssd, battery, airflow, other
}
public struct RawTemperature: Sendable, Codable, Hashable {
    public var name: String; public var celsius: Double
    public var group: TemperatureGroup              // classified by the sensor (TemperatureCatalog, from findings)
    public var source: Source; public enum Source: String, Sendable, Codable { case hid, smc }
}
public struct TemperatureReading: Sendable, Codable { public var sensors: [RawTemperature] }

public struct RawFan: Sendable, Codable, Hashable { public var index: Int; public var rpm, minRPM, maxRPM: Double; public var name: String? }
public struct SMCReading: Sendable, Codable {
    public var fans: [RawFan]
    public var temperatures: [RawTemperature]       // SMC T* keys worth keeping
    public var systemWatts: Double?                 // PSTR or equivalent, if found
}

public enum ThermalPressure: Int, Sendable, Codable, Comparable, CaseIterable { case nominal, fair, serious, critical }

public enum TransportProtocol: String, Sendable, Codable { case tcp, udp, quic, other }
public struct FlowCounter: Sendable, Codable, Hashable {
    public var flowID: UInt64
    public var pid: Int32, effectivePID: Int32?     // epid attributes XPC-proxied traffic
    public var proto: TransportProtocol
    public var rxBytes, txBytes: UInt64             // cumulative for the flow
    public var localPort: UInt16?, remoteAddress: String?, remotePort: UInt16?
    public var tcpState: String?, interface: String?
}
public struct NetworkFlowsReading: Sendable, Codable {
    public var flows: [FlowCounter]
    public var closedBytesByPID: [Int32: ByteCounts]   // bytes from flows removed since last sample
    public struct ByteCounts: Sendable, Codable, Hashable { public var rx, tx: UInt64 }
}
public enum InterfaceKind: String, Sendable, Codable { case wifi, ethernet, thunderbolt, cellular, other }
public struct InterfaceCounter: Sendable, Codable, Hashable {
    public var bsdName: String, displayName: String, kind: InterfaceKind, isUp: Bool, isPrimary: Bool
    public var rxBytes, txBytes: UInt64, ipv4: String?, linkRateBps: Double?
}
public struct InterfacesReading: Sendable, Codable { public var interfaces: [InterfaceCounter]; public var routerIPv4: String? }
public struct WiFiInfo: Sendable, Codable, Equatable {  // SSID dropped (ruling)
    public var interface: String, standardLabel: String?          // "Wi-Fi 6E"
    public var bandGHz: Double?, channel: Int?, channelWidthMHz: Int?
    public var rssi: Int?, noise: Int?, txRateMbps: Double?
}
public struct LatencyReading: Sendable, Codable, Equatable {
    public var target: String, lastRTTms: Double?, minMs: Double?, avgMs: Double?, maxMs: Double?
    public var lossFraction5m: Double?
}

public struct BlockDriverCounter: Sendable, Codable, Hashable {
    public var bsdName: String?, isInternal: Bool
    public var readOps, writeOps, readBytes, writeBytes: UInt64       // cumulative (IOBlockStorageDriver Statistics)
}
public struct DiskIOReading: Sendable, Codable { public var drivers: [BlockDriverCounter] }
public struct VolumeInfo: Sendable, Codable, Hashable, Identifiable {
    public var id: String                           // mount path
    public var name: String, bsdName: String?, fsType: String?, busLabel: String?   // "Internal", "USB-C"
    public var isInternal, isEjectable, isEncrypted: Bool
    public var totalBytes: UInt64, availableBytes: UInt64, availableImportantBytes: UInt64?
    public var purgeableBytes: UInt64? { get }      // importantAvail - avail
}
public struct VolumesReading: Sendable, Codable { public var volumes: [VolumeInfo] }
public enum SMARTStatus: String, Sendable, Codable { case healthy, warning, failing, unknown }
public struct SMARTInfo: Sendable, Codable, Equatable {
    public var model: String?, capacityBytes: UInt64?, status: SMARTStatus
    public var percentageUsed: Double?, dataReadBytes: UInt64?, dataWrittenBytes: UInt64?
    public var temperatureC: Double?, powerOnHours: Int?, unsafeShutdowns: Int?, criticalWarning: UInt8?
}

public struct BatteryReading: Sendable, Codable, Equatable {
    public var present: Bool, percent: Double?, isCharging: Bool, onAC: Bool
    public var minutesToEmpty: Int?, minutesToFull: Int?, cycleCount: Int?
    public var designCapacityWh: Double?, maxCapacityWh: Double?, currentCapacityWh: Double?
    public var voltageV: Double?, amperageA: Double?, temperatureC: Double?, condition: String?
    public var adapterWatts: Double?, adapterName: String?, lowPowerMode: Bool
}
public struct SleepAssertionsReading: Sendable, Codable { public var byPID: [Int32: [String]] }

public struct DeviceInfo: Sendable, Codable, Equatable {
    public var modelName: String                    // "MacBook Pro 14″"
    public var chipName: String                     // "Apple M4 Pro"
    public var performanceCores: Int, efficiencyCores: Int, gpuCores: Int?, neuralEngineCores: Int?
    public var memoryBytes: UInt64, memoryType: String?, memoryBandwidth: String?
    public var bootTime: Date, osVersion: String, hasBattery: Bool, fanCount: Int
    public static let placeholder: DeviceInfo
}
```

### 5.4 Sensor protocol, suite, raw tick (`MonitorModel/Sensors/*`)

```swift
public enum SensorID: String, CaseIterable, Sendable, Codable {
    case processes, hostCPU, memory, soc, gpuClients, temperatures, smc, thermalState
    case networkFlows, interfaces, wifi, latency, diskIO, volumes, smart, battery, sleepAssertions, device
}

public enum SensorError: Error, Sendable, Codable, Equatable {
    case unavailable(String)        // permanent for this launch (symbol missing, no hardware, rejected)
    case permissionDenied(String)
    case transient(String)          // retry next tick
    case timeout                    // async source didn't answer in budget
}

public enum SensorStatus: Sendable, Codable, Equatable {
    case ok
    case degraded(String)           // recent failures, showing stale/partial data
    case unavailable(String)        // "—" + tooltip text
    case disabled(String)           // user/env kill switch or crash canary
}

public struct SensorCadence: Sendable, Equatable {
    public var interactive: Duration                // min spacing while UI visible
    public var background: Duration?                // nil = don't sample in background
    public var requires: SamplingDemand             // [] = always; else only when demand ∩ requires ≠ ∅
    public static let everyTick: SensorCadence
    public static func every(_ d: Duration, background: Duration? = nil, requires: SamplingDemand = []) -> SensorCadence
}

public struct SampleContext: Sendable {
    public var uptimeNs: UInt64, wallTime: Date, mode: SamplingMode, demand: SamplingDemand
}

public protocol Sensor<Reading>: AnyObject {
    associatedtype Reading: Sendable & Codable
    var id: SensorID { get }
    var cadence: SensorCadence { get }
    /// Open handles. Called lazily on the sampler executor before first sample; may be called again after invalidate().
    func prepare() throws(SensorError)
    /// Must be fast (< budget in §7) and never block > 250 ms.
    func sample(_ ctx: SampleContext) throws(SensorError) -> Reading
    /// Release handles (pause, shutdown, repeated failure).
    func invalidate()
}

public final class UnavailableSensor<R: Sendable & Codable>: Sensor {   // W0 stub; also used for kill-switched sensors
    public init(_ id: SensorID, reason: String)
}
public final class FixtureSensor<R: Sendable & Codable>: Sensor {       // tests: replays readings in order
    public init(_ id: SensorID, readings: [Result<R, SensorError>], cadence: SensorCadence = .everyTick)
}

public struct SensorSuite {                           // non-Sendable: built and used inside SamplingEngine only
    public var processes: any Sensor<ProcessTableReading>
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
}

public struct SensorFactory: Sendable {
    public var make: @Sendable (_ disabled: Set<SensorID>) -> SensorSuite
    public init(make: @escaping @Sendable (Set<SensorID>) -> SensorSuite)
}
// MonitorSensors/LiveSensorFactory.swift:  public extension SensorFactory { static let live: SensorFactory }

public enum SensorResult<R: Sendable & Codable>: Sendable, Codable {
    case fresh(R)
    case cached(R, ageNs: UInt64)     // not due this tick; last good reading
    case failed(SensorError, last: R?)
    case notRequested
    public var value: R? { get }
}

public struct RawTick: Sendable, Codable {            // fixture format (telltale-probe --record)
    public var wallTime: Date, uptimeNs: UInt64, mode: SamplingMode, demand: SamplingDemand
    public var processes: SensorResult<ProcessTableReading>
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

Default cadences (W6 may tune within these; W7 verifies):

| Sensor | interactive | background | requires |
|---|---|---|---|
| processes, hostCPU, memory, soc, gpuClients, networkFlows, interfaces, diskIO, thermalState | every tick | every tick | — |
| temperatures (HID), smc | 2 s | 5 s | — (raw list only built when `.rawTemperatures`) |
| battery | 5 s | 30 s | — |
| latency | 10 s | 10 s | — (ruling: ICMP to router every 10 s) |
| wifi | 2 s | 30 s | — |
| volumes | 10 s | 60 s | — |
| sleepAssertions | 5 s | 60 s | — |
| smart | 300 s | never | `.smart` |
| device | once | once | — |

Connections (per-flow endpoints, reverse DNS) are part of `networkFlows`; endpoint/description fields are only filled when demand has `.connections`.

### 5.5 Snapshots (`MonitorModel/Snapshots/*`) — what the UI reads

```swift
public struct SystemFrame: Sendable, Codable, Equatable {
    public var wallTime: Date
    public var uptimeNs: UInt64
    public var interval: Duration?               // actual dt since previous frame; nil on first/after reset
    public var mode: SamplingMode
    public var device: DeviceInfo
    public var cpu: CPUSnapshot
    public var gpu: GPUSnapshot
    public var memory: MemorySnapshot
    public var network: NetworkSnapshot
    public var thermals: ThermalSnapshot
    public var power: PowerSnapshot
    public var disk: DiskSnapshot
    public var processes: [ProcessSample]        // all visible processes, unsorted
    public var apps: [AppSample]                 // grouped, sorted by cpuPercent desc
    public var connections: [ConnectionSample]   // empty unless demand ∋ .connections
    public var alert: AlertState
    public var events: [HistoryEvent]            // events closed/opened on this tick
    public var sensorHealth: [SensorID: SensorStatus]
    public var metrics: SystemMetrics            // flat vector of the above (history + live series)
    public static let empty: SystemFrame
}

public struct CoreUsage: Sendable, Codable, Hashable { public var index: Int; public var kind: CoreKind; public var usage: Double }
public struct ClusterSnapshot: Sendable, Codable, Hashable {
    public var kind: ClusterKind, coreCount: Int
    public var usage: Double?                    // mean of its cores (host ticks)
    public var activeResidency: Double?, frequencyMHz: Double?, maxFrequencyMHz: Double?, watts: Double?
}
public struct CPUSnapshot: Sendable, Codable, Equatable {
    public var usage: Double?, user: Double?, system: Double?, idle: Double?     // fractions of all cores
    public var cores: [CoreUsage]                // empty unless demand ∋ .perCore (per-core bars)
    public var clusters: [ClusterSnapshot]       // performance first
    public var loadAverage: [Double]?, threadCount: Int?, processCount: Int?
}
public struct GPUSnapshot: Sendable, Codable, Equatable {
    public var usage: Double?, frequencyMHz: Double?, maxFrequencyMHz: Double?, watts: Double?
    public var allocatedMemory: UInt64?, coreCount: Int?
    public var aneWatts: Double?                 // ANE: watts only (ruling)
    public var mediaEngines: [MediaEngineReading]
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
    public var rxBps: Double?, txBps: Double?    // primary/all active interfaces, excluding loopback
    public var interfaces: [InterfaceSnapshot]
    public var wifi: WiFiInfo?, routerIPv4: String?, localIPv4: String?
    public var latency: LatencyReading?
}
public struct TemperatureGroupSnapshot: Sendable, Codable, Hashable {
    public var group: TemperatureGroup, average: Double, maximum: Double, sensorCount: Int
}
public struct FanSnapshot: Sendable, Codable, Hashable, Identifiable {
    public var id: Int, name: String, rpm: Double, minRPM: Double, maxRPM: Double
}
public struct ThermalSnapshot: Sendable, Codable, Equatable {
    public var pressure: ThermalPressure?
    public var socAverage: Double?, hottest: RawTemperature?
    public var groups: [TemperatureGroupSnapshot]
    public var sensors: [RawTemperature]         // raw list; empty unless demand ∋ .rawTemperatures
    public var fans: [FanSnapshot]               // read-only (ruling)
}
public struct BatterySnapshot: Sendable, Codable, Equatable {
    public var percent: Double?, isCharging: Bool, onAC: Bool, timeRemaining: Duration?
    public var healthFraction: Double?, cycleCount: Int?, condition: String?
    public var maxCapacityWh: Double?, designCapacityWh: Double?, currentCapacityWh: Double?
    public var temperatureC: Double?, drainWatts: Double?     // negative = discharging
}
public struct PowerSnapshot: Sendable, Codable, Equatable {
    public var packageWatts: Double?, cpuWatts: Double?, gpuWatts: Double?, aneWatts: Double?, dramWatts: Double?
    public var systemWatts: Double?
    public var battery: BatterySnapshot?         // nil on desktops
    public var adapterWatts: Double?, adapterName: String?, lowPowerMode: Bool
}
public struct DiskSnapshot: Sendable, Codable, Equatable {
    public var readBps: Double?, writeBps: Double?, readIOPS: Double?, writeIOPS: Double?
    public var volumes: [VolumeInfo]
    public var bootVolume: VolumeInfo? { get }
    public var smart: SMARTInfo?
}

public struct ProcessSample: Sendable, Codable, Hashable, Identifiable {
    public var id: ProcessID
    public var pid: Int32 { get }
    public var name: String, path: String?, user: String?, uid: UInt32
    public var isCurrentUser: Bool               // gates Quit/Force Quit (ruling)
    public var app: AppKey
    public var cpuPercent: Double?, cpuTimeNs: UInt64?, threads: Int32?
    public var memory: UInt64?, compressed: UInt64?, privateBytes: UInt64?, ports: Int32?
    public var gpuPercent: Double?, gpuTimeNs: UInt64?
    public var netRxBps: Double?, netTxBps: Double?, netRxTotal: UInt64?, netTxTotal: UInt64?, connectionCount: Int?
    public var diskReadBps: Double?, diskWriteBps: Double?, diskReadTotal: UInt64?, diskWriteTotal: UInt64?
    public var energyWatts: Double?              // ri_billed_energy delta (ruling: watts, not score)
    public var preventsSleep: Bool
    public var restricted: Bool
}

public struct AppSample: Sendable, Codable, Hashable, Identifiable {
    public var id: AppKey { identity.key }
    public var identity: AppIdentity
    public var processIDs: [ProcessID]           // expand → processes
    public var isCurrentUser: Bool               // all member processes owned by current user
    public var cpuPercent: Double?, gpuPercent: Double?, memory: UInt64?
    public var netRxBps: Double?, netTxBps: Double?, diskReadBps: Double?, diskWriteBps: Double?
    public var energyWatts: Double?, threads: Int32?, connectionCount: Int?, preventsSleep: Bool
    public var metrics: AppMetrics               // same values as a vector
    public func value(for metric: AppMetric) -> Double?
}

public struct ConnectionSample: Sendable, Codable, Hashable, Identifiable {
    public var id: UInt64                        // flowID
    public var pid: Int32, app: AppKey, proto: TransportProtocol
    public var localPort: UInt16?, remoteAddress: String?, remotePort: UInt16?, remoteHost: String?   // reverse DNS (cached, async)
    public var tcpState: String?, rxBps: Double?, txBps: Double?, rxTotal: UInt64, txTotal: UInt64
}
```

Category ↔ app metric used for popover top-3 and treemap default:

| Category | top-3 key |
|---|---|
| cpu | `cpuPercent` |
| gpu | `gpuPercent` |
| memory | `memory` |
| network | `netRxBps + netTxBps` |
| thermals, power | `energyWatts` |
| disk | `diskReadBps + diskWriteBps` |

### 5.6 Engine APIs (`MonitorEngine`, W1)

```swift
/// Counter deltas → per-second rates. Handles first sight (nil), reset/wrap (value < previous → nil, rebaseline),
/// and pruning of keys that disappeared. Time is monotonic ns.
public struct RateCalculator<Key: Hashable & Sendable>: Sendable {
    public init()
    public mutating func rate(for key: Key, counter: UInt64, at uptimeNs: UInt64) -> Double?
    public mutating func delta(for key: Key, counter: UInt64, at uptimeNs: UInt64) -> (delta: UInt64, seconds: Double)?
    public mutating func prune(keeping live: Set<Key>)
    public mutating func reset()
    public var count: Int { get }
}

public enum CPUTicks {                            // pure
    public static func usage(previous: [CoreTicks], current: [CoreTicks]) -> (perCore: [Double], user: Double, system: Double, idle: Double)?
}

public struct AppGrouper {                        // pure given resolver
    public static func group(_ processes: [ProcessSample], identities: [AppKey: AppIdentity]) -> [AppSample]
}

public struct FrameAssembler {                    // owned by the engine actor
    public init(resolver: any AppResolving, currentUID: uid_t = getuid())
    public mutating func assemble(_ tick: RawTick) -> SystemFrame   // alert/events filled by caller
    public mutating func reset()                  // after wake / resume
}

public struct RecordConfig: Sendable {
    public var minCPUPercent = 0.5, minNetBps = 1024.0, minDiskBps = 102_400.0   // any GPU > 0 counts
    public var minMemory: UInt64 = 200 << 20      // keep large-memory apps in history
}
public struct RecordBuilder: Sendable {
    public init(config: RecordConfig = .init())
    public func record(from frame: SystemFrame) -> HistoryRecord   // apps above any threshold + one `.other` row
}

public actor SamplingEngine {
    public init(factory: SensorFactory, disabled: Set<SensorID> = [], alertConfig: AlertConfig = .init(),
                recordConfig: RecordConfig = .init(), canary: CrashCanary = .standard)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { get }   // DispatchSerialQueue
    public nonisolated let liveFrames: AsyncStream<SystemFrame>             // bufferingNewest(1)
    public nonisolated let records: AsyncStream<RecordBatch>                // unbounded; ~1 element / tick
    public func start()
    public func stop() async
    public func setVisibility(_ v: UIVisibility)  // → mode + demand; interactive switch samples immediately
    public func setPaused(_ paused: Bool)
    public func systemWillSleep()
    public func systemDidWake()
    public func sampleOnce() -> SystemFrame       // probe/tests: one synchronous tick
}
public struct RecordBatch: Sendable { public var record: HistoryRecord?; public var events: [HistoryEvent] }

/// Wraps one sensor: prepare-on-first-use, cadence, cache, error → status, backoff, cost stats.
final class SensorSlot<R: Sendable & Codable> {   // internal to MonitorEngine
    init(_ sensor: any Sensor<R>, canary: CrashCanary)
    func sample(_ ctx: SampleContext) -> SensorResult<R>
    var status: SensorStatus { get }
    var costNs: (last: UInt64, mean: UInt64, p95: UInt64) { get }
}

/// Persists "sensor X is being probed" in UserDefaults before first prepare()/sample() of a launch;
/// cleared after success. Marker present at next launch ⇒ sensor auto-disabled ("Disabled after crash").
public struct CrashCanary: Sendable { public static let standard: CrashCanary; public static let none: CrashCanary }
```

`LiveModel` (UI-facing, W0 writes a working basic version; W1 owns):

```swift
public enum LivePhase: Sendable, Equatable { case collecting(since: Date), live, paused(since: Date) }

@MainActor @Observable
public final class LiveModel {
    public init(device: DeviceInfo = .placeholder, historyCapacity: Int = 300, appHistoryCapacity: Int = 120)

    // Always updated (status icon depends on these even when no UI is visible)
    public private(set) var alert: AlertState
    public private(set) var phase: LivePhase
    public private(set) var samplingInterval: Duration?

    // Updated only while isPresenting == true (otherwise latest frame is kept unobserved and published on present)
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
    public private(set) var connections: [ConnectionSample]
    public private(set) var sensorHealth: [SensorID: SensorStatus]
    public private(set) var lastUpdate: Date?
    public private(set) var seriesVersion: Int                 // bumps per apply; charts observe this

    // Live history (ring buffers; always appended, cheap)
    public func series(_ metric: HistoryMetric, window: Duration = .seconds(60)) -> [SeriesPoint]
    public func appSeries(_ app: AppKey, _ metric: AppMetric, window: Duration = .seconds(60)) -> [SeriesPoint]

    // Derived
    public func topApps(_ category: Category, count: Int = 3) -> [AppSample]
    public var topConsumer: AppSample? { get }                 // max energyWatts, fallback cpuPercent; excludes .system/.other
    public func app(_ key: AppKey) -> AppSample?
    public func processes(of app: AppKey) -> [ProcessSample]
    public func status(of sensor: SensorID) -> SensorStatus    // .ok if absent

    // Input
    public func apply(_ frame: SystemFrame)
    public func setPaused(_ paused: Bool, at: Date)
}

public struct RingBuffer<Element>: RandomAccessCollection { // fixed capacity, O(1) append, no realloc
    public init(capacity: Int)
    public mutating func append(_ e: Element)
    public var capacity: Int { get }
}
```

### 5.7 Alerts & events (`MonitorModel/Alerts/*`, logic in `MonitorEngine/Alerts`)

```swift
public enum AlertLevel: Int, Sendable, Codable, Comparable { case calm, elevated, critical }

public struct ActiveAlert: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: Sendable, Codable, Equatable {
        case thermalPressure(ThermalPressure)
        case memoryPressure(MemoryPressureLevel)
        case runawayApp(AppKey, cpuPercent: Double)
    }
    public var id: String { get }                    // "thermal" | "memory" | "runaway:<key>"
    public var kind: Kind
    public var level: AlertLevel
    public var arc: IconArc                          // thermals | memory | cpu
    public var since: Date
    public var culprit: AppIdentity?                 // thermal: top energy app; memory: top memory app; runaway: itself
    public var culpritValue: Double?
}

public struct AlertState: Sendable, Codable, Equatable {
    public var level: AlertLevel                     // max over active; .calm if none
    public var arcs: [IconArc: AlertLevel]           // per-arc tint for the status glyph
    public var active: [ActiveAlert]                 // sorted by level desc, then since asc; first drives the banner
    public var pulseToken: Int                       // increments on each entry into .critical → icon pulses once
    public var paused: Bool
    public static let calm: AlertState
}

public struct AlertConfig: Sendable, Equatable {
    public var runawayEnterCPUPercent: Double = 150  // ≥ 1.5 cores …
    public var runawayEnterAfter: Duration = .seconds(300)   // … sustained 5 min (window mean, every sample ≥ 100)
    public var runawayExitCPUPercent: Double = 80
    public var runawayExitAfter: Duration = .seconds(30)
    public var stepDownHold: Duration = .seconds(10) // a level must be clear this long before stepping down
    public var runawayExcluded: Set<AppKey> = [.system, .other]
}

public struct AlertEngine: Sendable {
    public init(config: AlertConfig = .init())
    public private(set) var state: AlertState
    /// Returns the new state + transition events (entered/exited per alert id).
    public mutating func update(thermal: ThermalPressure?, memory: MemoryPressureLevel?, apps: [AppSample],
                                at now: Date) -> (state: AlertState, events: [HistoryEvent])
    public mutating func setPaused(_ paused: Bool, at now: Date) -> AlertState
}
```

State machine (per rule; overall = max):

```
            thermal fair / memory warning / runaway entered
   CALM ─────────────────────────────────────────────────▶ ELEVATED
    ▲  ◀──── condition clear for stepDownHold ─────────────   │
    │                                                          │ thermal serious|critical / memory critical
    │                                                          ▼
    └──── clear for stepDownHold (via ELEVATED if still fair/warn) ── CRITICAL  (pulseToken += 1 on entry)
```

| Input | Level | Arc |
|---|---|---|
| thermal nominal / fair / serious / critical | calm / elevated / critical / critical | thermals |
| memory normal / warning / critical | calm / elevated / critical | memory |
| runaway app (not critical by itself) | elevated | cpu |
| input `nil` (sensor unavailable) | treated as calm, never raises | — |
| paused | `level = .calm`, `paused = true` (glyph dimmed) | — |

Step-up is immediate; step-down waits `stepDownHold` (hysteresis, matches "stays red until the stress clears").

```swift
public struct HistoryEvent: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case thermalPressure, memoryPressure, runawayApp  // alert transitions (value = new level raw)
        case appEpisode                                   // app dominated a metric (History markers: "Xcode · 812% CPU")
        case swapGrowth                                   // swap grew ≥ 1 GB within 10 min
        case samplingPaused, systemSleep                  // gaps (end = resume/wake)
    }
    public var id: UUID
    public var kind: Kind
    public var start: Date, end: Date?
    public var level: AlertLevel
    public var app: AppIdentity?, metric: AppMetric?, peak: Double?
    public var label: String                              // ready-to-show marker text
}

public struct EpisodeConfig: Sendable {                   // EventDetector thresholds
    public var cpuPercent = 200.0, gpuPercent = 30.0, netBps = 10e6, diskBps = 50e6
    public var minDuration: Duration = .seconds(60), mergeGap: Duration = .seconds(30)
}
public struct EventDetector: Sendable {
    public init(config: EpisodeConfig = .init())
    public mutating func update(_ frame: SystemFrame) -> [HistoryEvent]   // emits on episode close
    public mutating func flush(at: Date) -> [HistoryEvent]                // on pause/quit
}
```

### 5.8 Store (`MonitorModel/History/*` protocols; `MonitorStore`, W2)

```swift
public struct AppRecord: Sendable, Codable, Equatable { public var identity: AppIdentity; public var metrics: AppMetrics }
public struct HistoryRecord: Sendable, Codable, Equatable {
    public var time: Date, interval: Duration
    public var system: SystemMetrics
    public var apps: [AppRecord]                         // above thresholds + `.other`
}

public struct AppShare: Sendable, Codable, Hashable, Identifiable {
    public var id: AppKey { identity.key }
    public var identity: AppIdentity, value: Double, fraction: Double
}
public struct AppAggregate: Sendable, Codable, Hashable {
    public var identity: AppIdentity, average: Double, peak: Double, total: Double?   // total = ∫rate dt (bytes)
}
public struct ExportSummary: Sendable, Equatable { public var rows: Int, bytes: Int, url: URL }

public protocol HistoryProvider: Sendable {
    /// Downsampled to ≤ maxPoints per metric; gap points (value nil) inserted where dt > 3× bucket.
    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, maxPoints: Int) async throws -> [HistoryMetric: [SeriesPoint]]
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, maxPoints: Int) async throws -> [AppMetric: [SeriesPoint]]
    /// Time-travel treemap: shares at the bucket containing `time` (resolution of the range's table).
    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare]
    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate]   // e.g. "12 h average"
    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double?                   // "Today ↓ 8.4 GB"
    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double?                    // "Peak (1 h)"
    func events(in interval: DateInterval) async throws -> [HistoryEvent]
    func coverage() async throws -> DateInterval?                         // nil = empty → "Collecting" state
    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary
}

public protocol HistoryRecorder: Sendable {
    func append(_ batch: RecordBatch) async
    func flush() async throws
    func maintain(now: Date) async throws                 // rollups + retention (+ incremental vacuum)
}

// MonitorStore
public actor HistoryStore: HistoryProvider, HistoryRecorder {
    public enum Location: Sendable { case file(URL), inMemory }
    public init(location: Location, config: StoreConfig = .init()) throws
    public nonisolated func flushSync()                   // applicationWillTerminate only
}
public struct StoreConfig: Sendable {
    public var flushInterval: Duration = .seconds(30), flushMaxRecords = 120
    public var rawRetention: Duration = .seconds(86_400)         // full resolution 24 h
    public var minuteRetention: Duration = .seconds(7 * 86_400)  // 1-min buckets 7 d
    public var quarterRetention: Duration = .seconds(30 * 86_400)// 15-min buckets 30 d (ruling: 30 d)
    public var maintenanceInterval: Duration = .seconds(300)
    public var now: @Sendable () -> Date = Date.init             // injectable clock
}
```

Schema (GRDB `DatabaseMigrator`, migration `v1`; `journal_mode=WAL`, `synchronous=NORMAL`, `auto_vacuum=INCREMENTAL`, `cache_size=-2000`):

```sql
app(id INTEGER PRIMARY KEY, key_kind TEXT, key_id TEXT, name TEXT, bundle_path TEXT, UNIQUE(key_kind, key_id))
system_raw(ts INTEGER PRIMARY KEY /*unix ms*/, interval_ms INTEGER, <one REAL column per HistoryMetric.rawValue>)
system_1m, system_15m  (ts PK = bucket start, n INTEGER, same REAL columns = averages)
app_raw(ts INTEGER, app_id INTEGER, cpu REAL, gpu REAL, memory REAL, netRx REAL, netTx REAL,
        diskRead REAL, diskWrite REAL, energy REAL, PRIMARY KEY(ts, app_id)) WITHOUT ROWID
app_1m, app_15m        (same + n INTEGER; averages over samples where the app was present; missing = 0)
event(id TEXT PRIMARY KEY, kind TEXT, start INTEGER, end INTEGER, level INTEGER, app_id INTEGER, metric TEXT, peak REAL, label TEXT)
CREATE INDEX event_start ON event(start)
```

Table choice per range: `hour`,`day` → `*_raw` (bucketed in SQL `GROUP BY ts / bucketMs`); `week` → `*_1m`; `month` → `*_15m`; `live` never hits the store. Rollup: each maintenance pass aggregates **completed** buckets idempotently (`INSERT OR REPLACE … SELECT … GROUP BY`), then deletes past retention. CSV: header `time,<metrics…>`, ISO-8601 UTC times, one row per stored bucket of the chosen range, streamed via cursor. DB path: `$TELLTALE_DATA_DIR` or `~/Library/Application Support/Telltale/history.sqlite`. Size estimate ≈ 25 MB/day raw (kept 24 h) + 13 MB (7 d of 1 m) + 5 MB (30 d of 15 m) → < 60 MB, under the 200 MB target.

### 5.9 Services, preferences, navigation (`MonitorModel/Services/*`)

```swift
public enum ProcessTarget: Sendable, Hashable {
    case app(AppIdentity, pids: [Int32])
    case process(pid: Int32, name: String, path: String?, uid: UInt32)
}
public enum ActionResult: Sendable, Equatable { case done, notPermitted, failed(String), cancelled }

public struct ProcessActions: Sendable {               // closures; W4 provides live, Mocks provide recording fake
    public var canControl: @MainActor @Sendable (ProcessTarget) -> Bool       // false for root/other users (ruling)
    public var quit: @MainActor @Sendable (ProcessTarget) async -> ActionResult
    public var forceQuit: @MainActor @Sendable (ProcessTarget) async -> ActionResult   // UI confirms first
    public var revealInFinder: @MainActor @Sendable (ProcessTarget) -> Void
    public var openInActivityMonitor: @MainActor @Sendable (ProcessTarget) -> Void
    public var eject: @MainActor @Sendable (VolumeInfo) async -> ActionResult  // Disk "Eject Archive"
    public static let noop: ProcessActions
}

public enum DashboardPage: String, CaseIterable, Sendable, Codable {
    case overview, cpu, gpu, memory, network, thermals, power, disk, processes, history
    public var title: String { get }                   // "Power & Battery" etc.
    public var section: Section { get }                // monitor | system | activity (sidebar groups)
    public enum Section: String, Sendable, CaseIterable { case monitor, system, activity }
}

public struct AppCommands: Sendable {
    public var openDashboard: @MainActor @Sendable (DashboardPage?) -> Void
    public var inspectApp: @MainActor @Sendable (AppKey) -> Void       // Processes page + inspector
    public var openSettings: @MainActor @Sendable () -> Void
    public var setPaused: @MainActor @Sendable (Bool) -> Void
    public var closePopover: @MainActor @Sendable () -> Void
    public var quitTelltale: @MainActor @Sendable () -> Void
    public static let noop: AppCommands
}

public struct UnitPreferences: Sendable, Codable, Equatable {
    public enum Temperature: String, Sendable, Codable, CaseIterable { case celsius, fahrenheit }
    public enum NetworkRate: String, Sendable, Codable, CaseIterable { case bytes, bits }
    public var temperature: Temperature = .celsius
    public var networkRate: NetworkRate = .bytes
}
public struct PopoverLayout: Sendable, Codable, Equatable {   // spec: rows reorderable/hideable (UserDefaults)
    public var order: [Category] = Category.allCases
    public var hidden: Set<Category> = []
}
```

SwiftUI environment (`MonitorUIKit/Environment/EnvironmentValues+Telltale.swift`, via `@Entry`): `processActions`, `appCommands`, `unitPreferences`, `popoverLayout`, `historyProvider: any HistoryProvider` (default `EmptyHistoryProvider`), `isSnapshot: Bool`, `now: Date?` (frozen time for snapshots). Observable objects via `.environment(_:)`: `LiveModel`, `NavigationModel`.

```swift
@MainActor @Observable public final class NavigationModel {   // MonitorScreens/Shell (W4)
    public var page: DashboardPage = .overview
    public var range: HistoryRange = .live                      // category pages: live/hour/day/week
    public var historyRange: HistoryRange = .day                // History page: hour/day/week/month
    public var processesMode: ProcessesMode = .apps             // Apps / Processes toggle
    public var selection: ProcessSelection?                     // inspector target
    public var historyScrub: Date?                              // nil = live treemap
    public enum ProcessesMode: String, Sendable { case apps, processes }
    public enum ProcessSelection: Hashable, Sendable { case app(AppKey), process(ProcessID) }
}
```

### 5.10 Runtime & mocks

```swift
// MonitorRuntime (W7; W0 writes the mock path)
public enum RuntimeMode: Sendable, Equatable { case live, mock(MockScenario) }
@MainActor public final class TelltaleRuntime {
    public static func make(mode: RuntimeMode, dataDirectory: URL, disabledSensors: Set<SensorID>) -> TelltaleRuntime
    public let live: LiveModel
    public let history: any HistoryProvider
    public func start()
    public func setVisibility(_ v: UIVisibility)       // → engine mode/demand + live.isPresenting
    public func setPaused(_ paused: Bool)
    public func systemWillSleep(); public func systemDidWake()
    public func shutdown()                              // stop engine, flushSync store
}
// Launch args / env (parsed by App/Composition/AppEnvironment.swift):
//   --mock <scenario> | TELLTALE_MOCK=<scenario>    mock runtime
//   --open-dashboard <page> | --open-popover         open UI at launch (perf + render checks)
//   TELLTALE_DATA_DIR=<dir>                          DB + defaults suite isolation per worktree
//   TELLTALE_DISABLE_SENSORS=nstat,soc,…             kill switch (also UserDefaults "DisabledSensors")

// MonitorMocks (W0)
public enum MockScenario: String, CaseIterable, Sendable, Codable {
    case calm            // MenuBar.dc / Main.dc numbers: Xcode 212.4 %, FCP 96.1 %, 24 GB M4 Pro …
    case thermalFair     // MenuBarAlert.dc: FCP culprit, fans 3,900 rpm
    case thermalCritical, memoryWarning, memoryCritical, runaway
    case collecting      // 0–1 frames, empty history
    case sensorsUnavailable  // soc, smc, networkFlows unavailable → "—" everywhere relevant
    case paused
}
public struct MockDataProvider: Sendable {
    public init(scenario: MockScenario, seed: UInt64 = 42, start: Date = MockDataProvider.referenceDate)
    public static let referenceDate: Date               // Thu 24 Sep 2026 14:32 local
    public var device: DeviceInfo { get }
    public func frame(at tick: Int) -> SystemFrame      // deterministic; alert state per scenario
    public func frames(interval: Duration) -> AsyncStream<SystemFrame>
    public func history() -> MockHistoryProvider
    public func processActions(log: ActionLog) -> ProcessActions
}
public final class MockHistoryProvider: HistoryProvider   // 30 days synthetic, History.dc bumps (Xcode build 14:30, FCP export 12:30 …)
public final class ActionLog: @unchecked Sendable        // records ProcessActions calls for tests (lock-protected)
```

A pre-filled model for previews/snapshots lives in `MonitorScreens/Shell/ScreenCatalog.swift` as `@MainActor static func LiveModel.mock(_ scenario: MockScenario, ticks: Int = 60) -> LiveModel` (applies `frame(at: 0..<ticks)`), because Mocks doesn't depend on Engine.

### 5.11 UI kit API (`MonitorUIKit`, W3; W0 writes compiling placeholders with these exact signatures)

Names below are Swift-side; W3 maps them to `docs/design/DESIGN.md` token/component names without renaming the Swift API. All members listed are `public` (modifier omitted for brevity).

```swift
public enum TTColor {       // static let … : Color
    static let background, sidebar, surface, surfaceRaised, stroke, rowAlt, selection: Color
    static let textPrimary, textSecondary, textTertiary, accent: Color
    static func category(_ c: Category) -> Color           // cpu, gpu, memory, network, thermals, power, disk series colors
    static func level(_ l: AlertLevel) -> Color            // calm = textPrimary, elevated = amber, critical = red
}
public enum TTFont { static let largeValue, title, headline, body, label, caption, tableNumber: Font }   // numbers .monospacedDigit()
public enum TTSpace { static let xs, s, m, l, xl: CGFloat }
public enum TTRadius { static let card, control, popover: CGFloat }

public enum Fmt {           // pure; all return "—" for nil
    static func percent(_ fraction: Double?, digits: Int = 0) -> String          // 0.421 → "42%"
    static func cpuPercent(_ p: Double?) -> String                               // 212.4 → "212.4%"
    static func bytes(_ b: UInt64?, style: ByteStyle = .memory) -> String        // "3.82 GB", "894 MB"
    static func rate(_ bps: Double?, units: UnitPreferences) -> String           // "8.1 MB/s", "12 KB/s" | bits
    static func temperature(_ c: Double?, units: UnitPreferences) -> String      // "74°C"
    static func watts(_ w: Double?, digits: Int = 1) -> String                   // "10.8 W"
    static func frequency(_ mhz: Double?) -> String                              // "4.12 GHz", "1,180 MHz"
    static func duration(_ d: Duration?) -> String                               // "5 h 40 m", "4 d 7 h"
    static func cpuTime(_ ns: UInt64?) -> String                                 // "2:41:07", "58:12"
    static func count(_ n: Int?) -> String                                       // "3,104"
    static func rpm(_ r: Double?) -> String                                      // "2,140 rpm"
    enum ByteStyle { case memory, file }
}

public struct MetricValue: View { init(_ text: String, isAvailable: Bool, unavailableReason: String?, font: Font = TTFont.body) }
public struct Panel<Content: View, Accessory: View>: View {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content)
}
public struct StatTile: View {       // "Total 42% of 12 cores", "Swap used 1.2 GB of 2.00 GB allocated"
    init(label: String, value: String, unit: String? = nil, detail: String? = nil, tint: Color? = nil, unavailableReason: String? = nil)
}
public struct Sparkline: View { init(_ points: [SeriesPoint], color: Color, maxValue: Double? = nil, fill: Bool = true) }   // Canvas
public struct LiveChart: View {      // Swift Charts; x = last `window`; gap-aware; "60 s ago … now" axis
    struct Series: Identifiable { var id: String; var label: String; var color: Color; var points: [SeriesPoint] }
    init(_ series: [Series], window: Duration = .seconds(60), yMax: Double? = nil, yFormat: @escaping (Double) -> String, stacked: Bool = false)
}
public struct HistoryChart: View {   // range charts, History lanes; scrub rule + event markers
    init(_ series: [LiveChart.Series], range: HistoryRange, end: Date, yMax: Double?, yFormat: @escaping (Double) -> String,
         events: [HistoryEvent] = [], scrub: Binding<Date?>? = nil, height: CGFloat = 58)
}
public struct StackedBar: View { struct Segment: Identifiable { var id: String; var label: String; var value: Double; var color: Color }
    init(_ segments: [Segment], total: Double, showsLegend: Bool = true) }
public struct CoreGrid: View { init(cores: [CoreUsage], kind: CoreKind, color: Color) }
public struct PressureScale: View { init(value: Double?, thresholds: [(Double, AlertLevel)]) }   // memory pressure bar
public struct ThermalPressureSteps: View { init(current: ThermalPressure?) }                     // Nominal/Fair/Serious/Critical
public struct RangePicker: View { init(selection: Binding<HistoryRange>, options: [HistoryRange]) }
public struct AppIcon: View { init(identity: AppIdentity?, name: String, size: CGFloat = 20) }  // NSWorkspace icon, else letter avatar
public struct DataTable<Row: Identifiable & Equatable>: View {                                    // LazyVStack; not NSTableView
    struct Column: Identifiable { var id: String; var title: String; var width: ColumnWidth; var alignment: HorizontalAlignment
                                  var sortKey: ((Row) -> Double?)?; var cell: (Row) -> AnyView }
    enum ColumnWidth { case flexible(min: CGFloat), fixed(CGFloat) }
    init(rows: [Row], columns: [Column], selection: Binding<Row.ID?>, sort: Binding<(column: String, descending: Bool)>,
         rowMenu: ((Row) -> AnyView)? = nil, expandable: ((Row) -> [Row])? = nil)
}
public struct AlertBanner: View { init(title: String, message: String, level: AlertLevel, actions: [BannerAction]) }
public struct BannerAction: Identifiable { var id: String; var title: String; var role: ButtonRole?; var perform: @MainActor () -> Void }
public struct EmptyState: View { init(_ kind: Kind); enum Kind { case collecting(since: Date?), unavailable(String), empty(String), paused } }
public struct ConfirmSheet: View { init(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) }
public struct Toast: View { init(_ text: String, undo: (() -> Void)? = nil) }
public struct PageScroll<Content: View>: View { init(@ViewBuilder _ content: () -> Content) }  // plain VStack when isSnapshot

public enum TreemapLayout {          // squarified (Bruls, Huizing, van Wijk); pure, TDD
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect]   // same order as input; zero/neg → .zero
    public static func worstAspectRatio(_ rects: [CGRect]) -> Double
}
public struct TreemapView: View { init(_ shares: [AppShare], color: (AppShare) -> Color, onSelect: ((AppKey) -> Void)? = nil) }

public struct StatusGlyph: View { init(state: AlertState, size: CGFloat = 16, template: Bool) }   // 5 arcs + center dot
@MainActor public enum StatusGlyphRenderer {
    static func image(for state: AlertState, pointSize: CGFloat = 18) -> NSImage   // isTemplate = (state.level == .calm)
}
```

### 5.12 App shell decisions (W4)

- `main.swift` + `AppDelegate` (AppKit lifecycle; no SwiftUI `App`), `NSApp.setActivationPolicy(.accessory)` (plus `LSUIElement`).
- Status item: `NSStatusItem.variableLength`, button image from `StatusGlyphRenderer`; observes `live.alert` via `withObservationTracking` re-armed on change.
- Popover: **borderless non-activating `NSPanel`** (not `NSPopover`): design shows a 360 pt dark rounded panel with no arrow, anchored under the status item. Closes on outside click (global mouse monitor), Esc, or status click. Content = `PopoverRoot` in `NSHostingView`, created on open, destroyed on close.
- Dashboard: `NSWindow` 1280×860 default, min 1040×700, `.fullSizeContentView`, transparent titlebar, `appearance = .darkAqua`, content `DashboardRoot`; released on close. Window delegate + `occlusionState` feed `VisibilityTracker`.
- Settings: separate small `NSWindow` hosting `SettingsView` (launch at login via `SMAppService.mainApp`, units, popover rows order/visibility, re-enable crashed sensors).
- `PowerEvents`: `NSWorkspace.willSleepNotification`/`didWakeNotification` → runtime.
- `ProcessActionsLive`: `NSRunningApplication.terminate()/forceTerminate()` for apps, `kill(SIGTERM/SIGKILL)` for processes; `canControl` = all pids owned by `getuid()`; Reveal via `NSWorkspace.activateFileViewerSelecting`; Activity Monitor via `NSWorkspace.openApplication(at:)`; eject via `NSWorkspace.unmountAndEjectDevice(at:)`.

---

## 6. Errors & unavailable data

Layers:
1. **Sensor**: `prepare()`/`sample()` throw `SensorError`; never crash on bad data (validate CF types, bounds-check C buffers). Async sources wait ≤ 250 ms then `.timeout`.
2. **SensorSlot** policy:
   - `.transient`/`.timeout`: return `.failed(err, last:)`; last reading reused ≤ 2 intervals, then values go `nil`. 3 consecutive failures → status `.degraded`, exponential backoff 2 s → 60 s.
   - `.unavailable`/`.permissionDenied`: status `.unavailable(reason)`, `invalidate()`, retry `prepare()` every 5 min.
   - Crash canary (§5.6): a private API that segfaults disables itself on next launch; status `.disabled("Disabled after a crash")`; Settings shows a "Re-enable sensors" button that clears markers.
   - Kill switch: `TELLTALE_DISABLE_SENSORS` / defaults `DisabledSensors` → `UnavailableSensor` substituted in the factory.
3. **Assembly**: `SensorResult` without value → the corresponding snapshot fields `nil`; `frame.sensorHealth` carries reasons. Process sweep: EPERM rows kept with `restricted = true`, counters `nil` (fallback path when libsysmon is out).
4. **UI**: `MetricValue(value, format, sensor:)` renders "—" with `.help(reason)` tooltip when `nil` (ruling). Pages show `EmptyState` for whole-panel unavailability (e.g., no battery on desktops, SMART status-only).
5. **States**: `LivePhase.collecting` until the first frame with rates (2nd tick) → skeleton "Collecting…" values; History: `coverage()` shorter than range → overlay "Collecting history · N min so far"; `nil` → empty state.
6. **Store**: DB open failure → log, run with `inMemory` store, History page shows "History unavailable" banner. Write failures: drop batch, keep app running, `os_log` fault. Schema from newer version → rename file aside, start fresh.
7. **Actions**: `canControl == false` → menu items disabled (ruling). Failures surface as `Toast`.

Logging: `os.Logger(subsystem: "dev.telltale", category: <module>)`; no `print` outside CLIs.

---

## 7. Performance design (advisory budget: UI closed < 1 % of one core avg, < 80 MB RSS)

Per-tick CPU budget at 5 s: < 50 ms total ⇒ target ≤ 25 ms. Estimates (replace with `docs/findings` numbers; W7 records measured p50/p95 via `telltale-probe --bench`):

| Step | Est. cost | Notes |
|---|---|---|
| process sweep (~600 pids) | 4–8 ms | `proc_listallpids` into a retained buffer; `proc_pid_rusage` V4 on stack; name/path/responsible/app only for **new** `ProcessID`s (cache) |
| libsysmon (if used) | TBD | one request, reuse request object if API allows |
| host_processor_info + vm stats | < 0.3 ms | `vm_deallocate` the processor info array every tick |
| IOReport sample + delta | 1–3 ms | subscription created once; iterate only subscribed channels |
| AGX user-client walk | 1–3 ms | iterator reused per tick; skip if no GPU clients changed? (measure) |
| HID temps | 2–6 ms | 2 s/5 s cadence; service clients cached; group means only unless `.rawTemperatures` |
| SMC fans | < 0.5 ms | key list cached at `prepare()` |
| NStat | 1–5 ms | long-lived manager; counts query per tick; descriptions only on source-add or `.connections` |
| getifaddrs, disk stats | < 1 ms | |
| assemble + alerts + record | 1–2 ms | dictionaries `reserveCapacity`, `removeAll(keepingCapacity: true)` |

Allocation avoidance:
- Engine keeps scratch buffers across ticks (pid buffer, `[ProcessID: Int]` index maps, per-key `RateCalculator` storage). No `Date()`/`DateFormatter` in hot loops; monotonic ns only.
- Strings interned per `ProcessID` (created once per process lifetime).
- `SystemMetrics`/`AppMetrics` fixed-size vectors instead of dictionaries.
- CF objects released within the tick (`takeRetainedValue` discipline); run the process under `leaks`/Instruments Allocations in W7.
- `SystemFrame` arrays are CoW: engine → MainActor send doesn't copy.

Background-mode cuts (UI closed): no per-core array, no raw temperature list, no connection endpoints/reverse DNS, no Wi-Fi details beyond 30 s, no SMART, volumes every 60 s; `LiveModel.isPresenting == false` ⇒ only `alert`, `phase`, ring buffers mutate (no view observes them; no SwiftUI work). Popover content and dashboard `NSHostingView` are **torn down on close** (window `isReleasedWhenClosed`, controller nils its hosting view) so their memory and observation cost go away.

Timers: `Task.sleep(until:tolerance:)` with tolerance 10 % of interval (coalescing). App Nap: W7 measures median background interval; if > 6 s, W4 holds a `ProcessInfo.beginActivity` assertion that keeps timers on schedule (options decided from measurement, verified with `pmset -g assertions` not preventing idle sleep).

UI redraw limits:
- Max one `LiveModel.apply` per sampling tick (1 Hz interactive). No `TimelineView`/animation-driven redraws; chart animations disabled (`.transaction { $0.animation = nil }`).
- Sparklines (popover, sidebar, tiles) = `Canvas`/`Path`, not Swift Charts. Swift Charts only for large page charts, ≤ 600 points per series (store downsamples; live ring = 60–300 pts).
- Tables: stable `Identifiable` ids (`ProcessID`, `AppKey`), `Equatable` row views (`.equatable()`), sort/filter in `ProcessTableModel` once per frame (not in `body`); render only visible rows (`LazyVStack`).
- App icons cached (`NSCache<NSString, NSImage>` by bundle path).
- Status glyph images cached per `(arcs, level, paused)` key; pulse = one 0.6 s alpha animation on the button layer.
- Occluded/miniaturized dashboard ⇒ `dashboardVisible = false` ⇒ background mode.

Memory: GRDB cache 2 MB; ring buffers ≈ 40 metrics × 300 × 16 B ≈ 0.2 MB; per-app live series only for apps currently in top 64 (120 pts) ≈ 1 MB; process table ≈ 0.2 MB/frame. Target idle RSS ≈ 45–60 MB.

Measurement (W7): `scripts/perf.sh 10` (live, UI closed, 10 min after 60 s warm-up) → avg %CPU, max RSS; `telltale-probe --bench --ticks 60` → per-sensor p50/p95 ms; interactive check with dashboard open on Processes page (report only; advisory).

---

## 8. Testing strategy

| Layer | Kind | Where | Command |
|---|---|---|---|
| Model | compile + Codable round-trip | `MonitorEngineTests/ModelCodableTests` | `scripts/test.sh ModelCodableTests` |
| Rates, CPU ticks, grouping, assembly, record builder, alerts, events, ring buffer, LiveModel | TDD unit, fixture-driven | `MonitorEngineTests` | `scripts/test.sh <Suite>` |
| Store | TDD against `HistoryStore(location: .inMemory)` with injected clock | `MonitorStoreTests` | `scripts/test.sh HistoryStoreTests` |
| Formatters, treemap layout, chart segmenting, glyph geometry | TDD unit | `MonitorUIKitTests` | `scripts/test.sh TreemapLayoutTests` |
| Components, screens | snapshot (PNG goldens) with mock scenarios | `MonitorUIKitTests`, `MonitorScreensTests` | `scripts/test.sh SnapshotTests` |
| Sensor decoding (IOReport channel map, HID name→group, SMC type decode, NStat dict→FlowCounter, SMART struct) | unit on captured plist/JSON from spikes | `MonitorSensorsTests/*ParseTests` | `scripts/test.sh IOReportParseTests` |
| Sensor FFI | smoke on this Mac, gated `TELLTALE_HW_TESTS=1` | `MonitorSensorsTests/*SmokeTests` | `TELLTALE_HW_TESTS=1 scripts/test.sh SMCSmokeTests` |
| Runtime | mock runtime + in-memory store end to end; frame → record → query | `MonitorRuntimeTests` | `scripts/test.sh RuntimeTests` |
| App | launch checkpoints, perf | manual script steps | `scripts/build.sh && scripts/run.sh` |

Framework: Swift Testing (`import Testing`, `@Test`, `#expect`) everywhere; `@MainActor` suites for view tests.

Fixtures:
- `telltale-probe --record Tests/MonitorEngineTests/Fixtures/<name>.json --ticks 20 --interval 1` writes `[RawTick]` from this machine (idle, `yes`-loaded, Chrome-helpers, sleep/wake). Engine tests replay: `FixtureLoader.ticks("idle-m1max")` → `FrameAssembler` → assertions. Until real fixtures exist, W1 uses builders (`RawTick.fixture { … }`) in `Tests/MonitorEngineTests/Support/`.
- Sensor parse fixtures: raw dumps (`.plist`/`.json`) captured by spikes/probe in `Tests/MonitorSensorsTests/Fixtures/`.
- Store: deterministic generated records (`HistoryRecord.synthetic(seconds:…)`); CSV golden file.

Snapshot/record tests (`MonitorUIKit/Snapshot/`, W3):

```swift
@MainActor public enum SnapshotRenderer {
    /// Fast path: ImageRenderer. Pure-SwiftUI views only (no ScrollView/NSViewRepresentable content).
    public static func imageRenderer<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> CGImage?
    /// Full path: offscreen borderless NSWindow + NSHostingView, darkAqua appearance, layout, 1 run-loop pass,
    /// bitmapImageRepForCachingDisplay + cacheDisplay. Renders Charts, ScrollView, AppKit-backed controls.
    public static func hosting<V: View>(_ view: V, size: CGSize, scale: CGFloat = 2) -> CGImage?
    public static func writePNG(_ image: CGImage, to url: URL) throws
}
public func assertSnapshot<V: View>(_ view: V, size: CGSize, named: String, path: SnapshotRenderer.Path = .hosting,
                                    tolerance: Double = 0.005, fileID: StaticString = #fileID, line: UInt = #line)
// Goldens: Tests/<Target>/__Snapshots__/<named>.png. Record: TELLTALE_RECORD=1. On failure writes
// .build/snapshot-failures/<named>.{actual,golden,diff}.png. Compare: fraction of pixels with any channel Δ > 8/255.
```

Determinism: environment `isSnapshot = true` (PageScroll renders a plain VStack, no blinking/animations), `now = MockDataProvider.referenceDate`, `Locale(identifier: "en_US")`, `TimeZone(identifier: "Europe/London")`, dark color scheme, scale 2, frames from `MockDataProvider(scenario:).frame(at: 60)`.

Design verification against artboards (manual-visual, per screen, done by the screen's owner and re-checked at integration checkpoints):
1. Reference PNGs: `docs/design/reference/<Artboard>.png` at artboard size (440×720, 640×330, 1280×860), @2x. Produced once (W3 T0) from the claude.ai canvas link via the browser tool (live values rendered), or fallback headless Chrome on the local `.dc.html` (`--headless=new --screenshot --window-size=W,H`; `{{…}}` placeholders stay visible — layout is still valid).
2. Render ours: `scripts/render.sh cpu calm` → `.build/renders/cpu-calm.png` (hosting path, same size as artboard). `ScreenCatalog` maps: `popover`→MenuBar, `popover-alert`→MenuBarAlert (thermalFair), `status-icons`→StatusIcon, `overview`→Main, `cpu`,`gpu`,`memory`,`network`,`thermals`,`power`,`disk`,`processes`,`history`.
3. Compare: agent reads both PNGs (Read tool renders images) and writes a checklist into the PR description: layout grid & spacing, typography, colors/tokens, copy, number formats, states. Optional `telltale-render --compare docs/design/reference/CPU.png` emits a side-by-side + overlay PNG for the reviewer. Pixel-exact match is **not** the goal (fonts/Charts differ); structural and token fidelity is.
4. After sign-off, the same render becomes the regression golden (`assertSnapshot` in `MonitorScreensTests`).

Test running rule (from user instructions): rerun only failing tests + tests of touched sources; full `swift test` only at integration checkpoints (shared-infrastructure change) or on request — say which reason when starting one.

---

## 9. Change control for locked interfaces

- `MonitorModel/**`, `Package.swift`, `project.yml`, `.gitignore`, `scripts/*` are owned by W0 (then the integrator; `project.yml` + `scripts/run.sh`/`install.sh` pass to W4, `scripts/perf.sh`/`probe.sh` to W7).
- A stream that needs a Model change writes `docs/icr/<NNN>-<stream>-<slug>.md` (what, why, exact Swift diff, who is affected) and continues against a local extension in its own target. The integrator lands ICRs in small `model:` commits on `dev`; streams rebase.
- Allowed without ICR: `extension` members in the stream's own target; new files in owned directories; new test fixtures.
- Compatibility: additive only (new optional fields with defaults, new enum cases only for enums with no exhaustive `switch` outside the owner, new protocol requirements only with default implementations).
