import Foundation
import MonitorModel

/// Deterministic, seeded fixture data for one `MockScenario` (ARCHITECTURE §5.11). `.calm` reproduces
/// the design artboards' headline numbers via the same seeded generator they use (`DemoSignals`); the
/// other scenarios reuse it with different parameters/overlays so every screen (MenuBar, Overview, CPU,
/// GPU, Memory, Network, Thermals, Power, Disk, Processes) gets plausible, internally consistent data.
///
/// `frame(at:)` is a pure function of `tick`: replaying the same tick always yields the same frame
/// (`MockDataProviderTests`: "same seed ⇒ same frames"), and it is cheap enough to call per-tick from a
/// `LiveModel.mock` warm-up loop or a `MockPipeline` timer.
public struct MockDataProvider: Sendable {
    public let scenario: MockScenario
    public let seed: UInt64
    public let start: Date
    public let device: DeviceInfo

    private let signals: DemoSignals
    private let apps: [DemoApp]

    public init(scenario: MockScenario, seed: UInt64 = 42, start: Date = MockDataProvider.referenceDate) {
        self.scenario = scenario
        self.seed = seed
        self.start = start
        self.device = DemoDevice.device(referenceDate: start)
        self.signals = DemoSignals(scenario: scenario)
        var roster = DemoApps.roster(scenario: scenario)
        if scenario == .restricted {
            roster += DemoApps.extraApps(count: 24, seedOffset: seed)
        }
        self.apps = roster
    }

    /// Thu 24 Sep 2026 14:32 local.
    public static let referenceDate: Date = {
        let components = DateComponents(year: 2026, month: 9, day: 24, hour: 14, minute: 32)
        return Calendar.current.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }()

    public func frame(at tick: Int) -> SystemFrame {
        let clampedTick = max(tick, 0)
        let wallTime = start.addingTimeInterval(TimeInterval(clampedTick))
        let uptimeNs = UInt64(max(0, wallTime.timeIntervalSince(device.bootTime)) * 1_000_000_000)

        let mode: SamplingMode = scenario == .paused ? .paused : .interactive
        // No previous sample on the very first tick (still collecting); `.collecting` never leaves that phase.
        let interval: Duration? = (scenario == .collecting || scenario == .paused || clampedTick == 0)
            ? nil : .seconds(1)

        // Build the named rows first, so the system-level snapshots below can grow to at least cover them
        // (never the other way around) — the "sums consistent" invariant then holds by construction,
        // never by clamping a possibly-too-small nominal total down to zero.
        var processes = apps.map { DemoApps.makeProcess($0, at: clampedTick) }
        if scenario == .restricted {
            processes += DemoRestricted.processes(seed: seed, tick: clampedTick)
        }
        let namedApps = DemoApps.group(processes)
        let named = Self.NamedTotals(namedApps)
        let totalCores = Double(device.performanceCores + device.efficiencyCores)

        let cpu = makeCPU(tick: clampedTick, namedCoreUnits: named.cpu)
        let memory = makeMemory(tick: clampedTick, namedMemory: named.memory)
        let network = makeNetwork(tick: clampedTick, namedRx: named.netRx, namedTx: named.netTx)
        let disk = makeDisk(tick: clampedTick, namedRead: named.diskRead, namedWrite: named.diskWrite)

        let other = AppSample(
            identity: AppIdentity(key: .other, displayName: "Other"),
            isCurrentUser: false,
            cpuPercent: max(0, cpu.usagePercent * totalCores - named.cpu),
            gpuPercent: 0,
            memory: (memory.appMemory ?? 0) > named.memory ? (memory.appMemory ?? 0) - named.memory : 0,
            netRxBps: max(0, (network.rxBps ?? 0) - named.netRx),
            netTxBps: max(0, (network.txBps ?? 0) - named.netTx),
            diskReadBps: max(0, (disk.readBps ?? 0) - named.diskRead),
            diskWriteBps: max(0, (disk.writeBps ?? 0) - named.diskWrite),
            energyWatts: nil,
            energyEstimated: false
        )
        let allApps = (namedApps + [other]).sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }

        let gpu = makeGPU(tick: clampedTick)
        let thermals = makeThermals(tick: clampedTick)
        let power = makePower(tick: clampedTick, batteryPercent: 82)
        let sensorHealth = makeSensorHealth()
        let alert = makeAlert()

        var frame = SystemFrame(
            wallTime: wallTime,
            uptimeNs: uptimeNs,
            interval: interval,
            mode: mode,
            device: device,
            cpu: cpu.snapshot,
            gpu: gpu,
            memory: memory,
            network: network,
            thermals: thermals,
            power: power,
            disk: disk,
            processes: processes,
            apps: allApps,
            connections: makeConnections(),
            alert: alert,
            events: [],
            sensorHealth: sensorHealth,
            metrics: makeMetrics(cpu: cpu.snapshot, gpu: gpu, memory: memory, network: network,
                                  thermals: thermals, power: power, disk: disk)
        )
        applyScenarioUnavailability(to: &frame)
        return frame
    }

    /// `.collecting`: nothing that needs two samples is available yet (every rate/delta), only
    /// instantaneous reads (memory levels, thermals, load average, process/app identity + memory).
    /// `.sensorsUnavailable` (soc/smc/networkFlows): per-app/process network, which comes only from
    /// `networkFlows` — CPU/GPU-usage/memory/disk/thermal-pressure/interface totals use other sensors and
    /// stay put (already handled field-by-field in `makeGPU`/`makeThermals`/`makePower`).
    private func applyScenarioUnavailability(to frame: inout SystemFrame) {
        switch scenario {
        case .collecting:
            frame.cpu.usage = nil; frame.cpu.user = nil; frame.cpu.system = nil; frame.cpu.idle = nil
            frame.cpu.cores = []; frame.cpu.clusters = []
            frame.gpu.usage = nil; frame.gpu.frequencyMHz = nil; frame.gpu.watts = nil; frame.gpu.aneWatts = nil
            frame.gpu.mediaEngines = []
            frame.network.rxBps = nil; frame.network.txBps = nil
            frame.network.interfaces = frame.network.interfaces.map { i in
                var i = i; i.rxBps = nil; i.txBps = nil; return i
            }
            frame.disk.readBps = nil; frame.disk.writeBps = nil; frame.disk.readIOPS = nil; frame.disk.writeIOPS = nil
            frame.processes = frame.processes.map(Self.clearingRates)
            frame.apps = frame.apps.map(Self.clearingRates)
            frame.connections = []

        case .sensorsUnavailable:
            frame.processes = frame.processes.map { p in
                var p = p; p.netRxBps = nil; p.netTxBps = nil; p.netRxTotal = nil; p.netTxTotal = nil
                p.connectionCount = nil; return p
            }
            frame.apps = frame.apps.map { a in
                guard a.identity.key != .other else { return a }   // `.other`'s residual stays put below
                var a = a; a.netRxBps = nil; a.netTxBps = nil; a.netRxSession = nil; a.netTxSession = nil
                a.connectionCount = nil; return a
            }
            frame.connections = []

        default:
            break
        }
    }

    private static func clearingRates(_ p: ProcessSample) -> ProcessSample {
        var p = p
        p.cpuPercent = nil; p.gpuPercent = nil
        p.netRxBps = nil; p.netTxBps = nil; p.netRxTotal = nil; p.netTxTotal = nil
        p.diskReadBps = nil; p.diskWriteBps = nil; p.diskReadTotal = nil; p.diskWriteTotal = nil
        p.energyWatts = nil
        return p
    }

    private static func clearingRates(_ a: AppSample) -> AppSample {
        var a = a
        a.cpuPercent = nil; a.gpuPercent = nil
        a.netRxBps = nil; a.netTxBps = nil; a.diskReadBps = nil; a.diskWriteBps = nil
        a.energyWatts = nil
        return a
    }

    /// A few live flows on network-active apps (Safari, Dropbox), so the Processes inspector's
    /// "Live connections" table has something to show regardless of which app a test/render inspects.
    private func makeConnections() -> [ConnectionSample] {
        guard scenario != .sensorsUnavailable, scenario != .collecting else { return [] }
        let safari = (ProcessID(pid: 967, startTimeUs: 1), AppKey(kind: .app, id: "com.apple.Safari"))
        let dropbox = (ProcessID(pid: 703, startTimeUs: 1), AppKey(kind: .app, id: "com.getdropbox.dropbox"))
        return [
            ConnectionSample(id: 1, process: safari.0, app: safari.1, proto: .tcp, localPort: 51_820,
                              remoteAddress: "142.250.72.14", remotePort: 443, remoteHost: "www.google.com",
                              tcpState: "ESTABLISHED", rxBps: 42_000, txBps: 6_000, rxTotal: 1_200_000, txTotal: 300_000),
            ConnectionSample(id: 2, process: safari.0, app: safari.1, proto: .tcp, localPort: 51_821,
                              remoteAddress: "151.101.1.69", remotePort: 443, remoteHost: "github.com",
                              tcpState: "ESTABLISHED", rxBps: 18_000, txBps: 2_000, rxTotal: 800_000, txTotal: 150_000),
            ConnectionSample(id: 3, process: safari.0, app: safari.1, proto: .tcp, localPort: 51_822,
                              remoteAddress: "17.253.5.203", remotePort: 443, tcpState: "ESTABLISHED",
                              rxBps: 4_000, txBps: 1_000, rxTotal: 200_000, txTotal: 90_000),
            ConnectionSample(id: 4, process: dropbox.0, app: dropbox.1, proto: .tcp, localPort: 52_010,
                              remoteAddress: "162.125.66.1", remotePort: 443, remoteHost: "dl-client.dropbox.com",
                              tcpState: "ESTABLISHED", rxBps: 180_000, txBps: 20_000, rxTotal: 5_400_000, txTotal: 600_000),
            ConnectionSample(id: 5, process: dropbox.0, app: dropbox.1, proto: .tcp, localPort: 52_011,
                              remoteAddress: "162.125.66.7", remotePort: 443, remoteHost: "notify.dropboxapi.com",
                              tcpState: "ESTABLISHED", rxBps: 800, txBps: 800, rxTotal: 40_000, txTotal: 40_000),
        ]
    }

    public func frames(interval: Duration) -> AsyncStream<SystemFrame> {
        AsyncStream { continuation in
            let task = Task {
                var tick = 0
                while !Task.isCancelled {
                    continuation.yield(frame(at: tick))
                    tick += 1
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func history() -> MockHistoryProvider {
        MockHistoryProvider(scenario: scenario, seed: seed, end: start)
    }

    /// Records every call to `log` and mimics `canControl`'s real-world rule (false for root/other-user
    /// processes and synthetic coalition rows): `.app` targets are controllable when they're a real
    /// bundled app (our roster's daemons — WindowServer, mds_stores — use `AppKey.Kind.process`);
    /// `.process` targets are controllable when they run as the mock's own user (uid 501, DemoApps'
    /// `isCurrentUser` convention).
    public func processActions(log: ActionLog) -> ProcessActions {
        func name(_ target: ProcessTarget) -> String {
            switch target {
            case .app(let identity, _): identity.displayName
            case .process(_, let name, _, _): name
            }
        }
        func controllable(_ target: ProcessTarget) -> Bool {
            switch target {
            case .app(let identity, _): identity.key.kind == .app
            case .process(_, _, _, let uid): uid == 501
            }
        }
        return ProcessActions(
            canControl: { controllable($0) },
            quit: { target in
                let result: ActionResult = controllable(target) ? .done : .notPermitted
                log.record(.quit, target: name(target), result: result)
                return result
            },
            forceQuit: { target in
                let result: ActionResult = controllable(target) ? .done : .notPermitted
                log.record(.forceQuit, target: name(target), result: result)
                return result
            },
            revealInFinder: { target in
                log.record(.revealInFinder, target: name(target), result: .done)
            },
            openInActivityMonitor: { target in
                log.record(.openInActivityMonitor, target: name(target), result: .done)
            },
            eject: { volume in
                let result: ActionResult = volume.isEjectable ? .done : .notPermitted
                log.record(.eject, target: volume.name, result: result)
                return result
            }
        )
    }

    // MARK: - CPU

    private struct CPUResult { var snapshot: CPUSnapshot; var usagePercent: Double }

    /// `namedCoreUnits`: sum of the named apps' `cpuPercent` ("% of one core" units) at this tick.
    /// The headline total is grown to at least cover it (never clamped down), so
    /// `cpu.usage * 100 * totalCores == sum(apps.cpuPercent)` always holds exactly (`.other` fills the gap).
    private func makeCPU(tick: Int, namedCoreUnits: Double) -> CPUResult {
        let totalCores = Double(device.performanceCores + device.efficiencyCores)
        let nominalPercent = signals.value(.cpu, at: tick)
        let totalPercent = max(nominalPercent, namedCoreUnits / totalCores)
        let growth = nominalPercent > 0 ? totalPercent / nominalPercent : 1
        let usr = signals.value(.usr, at: tick)
        let sys = signals.value(.sys, at: tick)
        let ratio = usr / max(usr + sys, 0.0001)
        let userPercent = totalPercent * ratio
        let systemPercent = totalPercent * (1 - ratio)
        let idlePercent = max(0, 100 - totalPercent)

        let perfKeys: [DemoKey] = [.p0, .p1, .p2, .p3, .p4, .p5, .p6, .p7]
        let effKeys: [DemoKey] = [.e0, .e1, .e2, .e3]
        let perfCores = perfKeys.enumerated().map { i, k in
            CoreUsage(index: i, kind: .performance, usage: Self.fraction(min(100, signals.value(k, at: tick) * growth)))
        }
        let effCores = effKeys.enumerated().map { i, k in
            CoreUsage(index: 8 + i, kind: .efficiency, usage: Self.fraction(min(100, signals.value(k, at: tick) * growth)))
        }
        let pClusterUsage = perfCores.map(\.usage).reduce(0, +) / Double(perfCores.count)
        let eClusterUsage = effCores.map(\.usage).reduce(0, +) / Double(effCores.count)
        let clusters = [
            ClusterSnapshot(kind: .performance, coreCount: perfCores.count, usage: pClusterUsage,
                             activeResidency: pClusterUsage, frequencyMHz: 4_120, maxFrequencyMHz: 4_510,
                             watts: signals.value(.pc, at: tick) * 0.7),
            ClusterSnapshot(kind: .efficiency, coreCount: effCores.count, usage: eClusterUsage,
                             activeResidency: eClusterUsage, frequencyMHz: 2_590, maxFrequencyMHz: 2_890,
                             watts: signals.value(.pc, at: tick) * 0.3),
        ]

        let snapshot = CPUSnapshot(
            usage: Self.fraction(totalPercent),
            user: Self.fraction(userPercent),
            system: Self.fraction(systemPercent),
            idle: Self.fraction(idlePercent),
            cores: perfCores + effCores,
            clusters: clusters,
            loadAverage: [3.21, 2.88, 2.54],
            threadCount: 3_104,
            processCount: 612
        )
        return CPUResult(snapshot: snapshot, usagePercent: totalPercent)
    }

    // MARK: - GPU

    /// `usage` can come from `gpuClients` (AGX) even without `soc`, so it stays available in
    /// `.sensorsUnavailable`; frequency/watts/ANE watts/media engines are soc (IOReport) only.
    private func makeGPU(tick: Int) -> GPUSnapshot {
        let encPercent = signals.value(.enc, at: tick)
        let socAvailable = scenario != .sensorsUnavailable
        return GPUSnapshot(
            usage: Self.fraction(signals.value(.gpu, at: tick)),
            frequencyMHz: socAvailable ? signals.value(.gfreq, at: tick) : nil,
            maxFrequencyMHz: socAvailable ? 1_578 : nil,
            watts: socAvailable ? signals.value(.pg, at: tick) : nil,
            allocatedMemory: 3_100 * 1_048_576,
            coreCount: device.gpuCores,
            aneWatts: socAvailable ? signals.value(.pa, at: tick) : nil,
            mediaEngines: socAvailable ? [
                MediaEngineReading(name: "Video encode", activeFraction: Self.fraction(encPercent)),
                MediaEngineReading(name: "Video decode", activeFraction: Self.fraction(encPercent * 0.6)),
                MediaEngineReading(name: "ProRes engine", activeFraction: Self.fraction(encPercent * 0.3)),
            ] : []
        )
    }

    // MARK: - Memory

    /// `namedMemory`: sum of the named apps' `memory` (bytes) at this tick. `appMemory` is grown to at
    /// least this much (never clamped down), so `.other` never has to absorb a negative residual —
    /// the "sums consistent" invariant holds by construction.
    private func makeMemory(tick: Int, namedMemory: UInt64) -> MemorySnapshot {
        // Wired/compressed stay small and roughly fixed (realistic order of magnitude); everything else
        // `used` reports is `appMemory`, which must cover at least the named apps.
        let wired = UInt64(1.4 * 1_073_741_824)
        let compressed = UInt64(0.9 * 1_073_741_824)
        let nominalUsed = UInt64(signals.value(.mem, at: tick) * 1_073_741_824)
        let nominalAppMemory = nominalUsed > wired + compressed ? nominalUsed - wired - compressed : 0
        let appMemory = max(nominalAppMemory, namedMemory)
        let usedBytes = appMemory + wired + compressed
        let free = device.memoryBytes > usedBytes ? device.memoryBytes - usedBytes : 0
        let cachedFiles = UInt64(Double(free) * 0.4)
        let pressurePercent = signals.value(.press, at: tick)
        let level: MemoryPressureLevel = pressurePercent >= 80 ? .critical : (pressurePercent >= 60 ? .warning : .normal)

        return MemorySnapshot(
            total: device.memoryBytes,
            used: usedBytes,
            appMemory: appMemory,
            wired: wired,
            compressed: compressed,
            cachedFiles: cachedFiles,
            free: free - cachedFiles,
            compressionRatio: 2.8,
            pressureLevel: level,
            pressureFraction: Self.fraction(pressurePercent),
            swapUsed: UInt64(signals.value(.swap, at: tick) * 1_073_741_824),
            swapTotal: 2 * 1_073_741_824,
            swapFileCount: 2,
            pageInsPerSec: 412,
            pageOutsPerSec: 0,
            swapInsPerSec: 0,
            swapOutsPerSec: 0
        )
    }

    // MARK: - Network

    /// `namedRx`/`namedTx`: sum of the named apps' network bps at this tick; totals grow to at least
    /// cover them (see `makeCPU`/`makeMemory`).
    private func makeNetwork(tick: Int, namedRx: Double, namedTx: Double) -> NetworkSnapshot {
        let rxBps = max(signals.value(.netd, at: tick) * 1_000_000, namedRx)
        let txBps = max(signals.value(.netu, at: tick) * 1_000_000, namedTx)
        let interfaces = [
            InterfaceSnapshot(bsdName: "en0", displayName: "Wi-Fi", kind: .wifi, isUp: true, isPrimary: true,
                               rxBps: rxBps, txBps: txBps, ipv4: "192.168.1.24", linkRateBps: 1_201_000_000),
            InterfaceSnapshot(bsdName: "en5", displayName: "Thunderbolt Ethernet", kind: .thunderbolt, isUp: false,
                               isPrimary: false),
        ]
        let wifi = WiFiInfo(interface: "en0", standardLabel: "Wi-Fi 6E", bandGHz: 5, channel: 149,
                             channelWidthMHz: 80, rssi: -52, noise: -90, txRateMbps: 1_201)
        let latency = LatencyReading(target: "192.168.1.1", lastRTTms: 18, minMs: 12, avgMs: 18, maxMs: 26,
                                     lossFraction5m: 0)
        return NetworkSnapshot(rxBps: rxBps, txBps: txBps, interfaces: interfaces, wifi: wifi,
                                routerIPv4: "192.168.1.1", localIPv4: "192.168.1.24", latency: latency)
    }

    // MARK: - Thermals

    private func makeThermals(tick: Int) -> ThermalSnapshot {
        let socTemp = signals.value(.temp, at: tick)
        let pTemp = signals.value(.tp, at: tick)
        let gTemp = signals.value(.tg, at: tick)
        let bTemp = signals.value(.tb, at: tick)
        // `.thermalState` is its own sensor, separate from `smc`/`soc`, so thermal pressure stays
        // available even in `.sensorsUnavailable` (only the smc/hid-sourced temps/fans below go nil).
        let pressure: ThermalPressure =
            switch scenario {
            case .thermalCritical: .critical
            case .thermalFair: .fair
            default: .nominal
            }
        let groups = [
            TemperatureGroupSnapshot(group: .cpuPerformance, average: pTemp, maximum: pTemp + 8, sensorCount: 8),
            TemperatureGroupSnapshot(group: .cpuEfficiency, average: pTemp - 12, maximum: pTemp - 4, sensorCount: 4),
            TemperatureGroupSnapshot(group: .gpu, average: gTemp, maximum: gTemp + 6, sensorCount: 4),
            TemperatureGroupSnapshot(group: .soc, average: socTemp, maximum: socTemp + 4, sensorCount: 12),
            TemperatureGroupSnapshot(group: .ssd, average: 41, maximum: 46, sensorCount: 1),
            TemperatureGroupSnapshot(group: .battery, average: bTemp, maximum: bTemp + 2, sensorCount: 1),
            TemperatureGroupSnapshot(group: .airflow, average: socTemp - 22, maximum: socTemp - 14, sensorCount: 2),
        ]
        let sensors = [
            RawTemperature(name: "PMU die", celsius: pTemp + 8, group: .cpuPerformance, source: .hid),
            RawTemperature(name: "SoC package", celsius: socTemp, group: .soc, source: .smc),
            RawTemperature(name: "NAND", celsius: 41, group: .ssd, source: .smc),
            RawTemperature(name: "Battery cell avg", celsius: bTemp, group: .battery, source: .smc),
        ]
        // `DemoDevice` always models a two-fan MacBook Pro (no "no fans" scenario exists), so this is
        // never conditional on `device.fanCount`.
        let fans: [FanSnapshot] = [
            FanSnapshot(id: 0, name: "Left fan", rpm: signals.value(.fan1, at: tick), minRPM: 1_200, maxRPM: 5_700),
            FanSnapshot(id: 1, name: "Right fan", rpm: signals.value(.fan2, at: tick), minRPM: 1_200, maxRPM: 5_700),
        ]
        return ThermalSnapshot(
            pressure: pressure,
            socAverage: scenario == .sensorsUnavailable ? nil : socTemp,
            hottest: scenario == .sensorsUnavailable ? nil
                : RawTemperature(name: "P-core cluster, die 3", celsius: pTemp + 8, group: .cpuPerformance, source: .hid),
            groups: scenario == .sensorsUnavailable ? [] : groups,
            sensors: scenario == .sensorsUnavailable ? [] : sensors,
            fans: scenario == .sensorsUnavailable ? [] : fans,
            approximateMapping: false
        )
    }

    // MARK: - Power

    private func makePower(tick: Int, batteryPercent: Double) -> PowerSnapshot {
        let package = signals.value(.pwr, at: tick)
        let battery = BatterySnapshot(
            percent: batteryPercent,
            isCharging: false,
            onAC: false,
            timeRemaining: .seconds(5 * 3_600 + 40 * 60),
            healthFraction: 0.94,
            cycleCount: 212,
            condition: "Normal",
            maxCapacityWh: 68.1,
            designCapacityWh: 72.4,
            currentCapacityWh: 68.1 * batteryPercent / 100,
            temperatureC: signals.value(.tb, at: tick),
            drainWatts: -18.9
        )
        return PowerSnapshot(
            packageWatts: scenario == .sensorsUnavailable ? nil : package,
            cpuWatts: scenario == .sensorsUnavailable ? nil : signals.value(.pc, at: tick),
            gpuWatts: scenario == .sensorsUnavailable ? nil : signals.value(.pg, at: tick),
            aneWatts: scenario == .sensorsUnavailable ? nil : signals.value(.pa, at: tick),
            dramWatts: scenario == .sensorsUnavailable ? nil : signals.value(.pd, at: tick),
            systemWatts: scenario == .sensorsUnavailable ? nil : package * 0.97,
            battery: battery,
            adapterWatts: nil,
            adapterName: nil,
            lowPowerMode: false
        )
    }

    // MARK: - Disk

    /// `namedRead`/`namedWrite`: sum of the named apps' disk bps at this tick; totals grow to at least
    /// cover them (see `makeCPU`/`makeMemory`).
    private func makeDisk(tick: Int, namedRead: Double, namedWrite: Double) -> DiskSnapshot {
        let readBps = max(signals.value(.rd, at: tick) * 1_000_000, namedRead)
        let writeBps = max(signals.value(.wr, at: tick) * 1_000_000, namedWrite)
        let boot = VolumeInfo(
            id: "/", name: "Macintosh HD", bsdName: "disk3s5", fsType: "APFS", busLabel: "Internal",
            isInternal: true, isEjectable: false, isEncrypted: true,
            totalBytes: 994 * 1_000_000_000, availableBytes: 382 * 1_000_000_000,
            availableImportantBytes: 400 * 1_000_000_000
        )
        let smart = SMARTInfo(
            model: "APPLE SSD AP1024Z", capacityBytes: 1_000_000_000_000, status: .healthy,
            percentageUsed: 2, dataReadBytes: UInt64(61.7 * 1e12), dataWrittenBytes: UInt64(48.2 * 1e12),
            temperatureC: 41, powerOnHours: 3_412, unsafeShutdowns: 3, criticalWarning: 0
        )
        return DiskSnapshot(readBps: readBps, writeBps: writeBps, readIOPS: 3_400, writeIOPS: 900,
                             volumes: [boot], smart: smart)
    }

    // MARK: - Sensor health

    private func makeSensorHealth() -> [SensorID: SensorStatus] {
        guard scenario == .sensorsUnavailable else { return [:] }
        return [
            .soc: .unavailable("IOReport channels not available on this Mac"),
            .smc: .unavailable("SMC driver not found"),
            .networkFlows: .unavailable("NetworkStatistics entitlement missing"),
        ]
    }

    // MARK: - Alert

    private func makeAlert() -> AlertState {
        switch scenario {
        case .calm, .collecting, .sensorsUnavailable:
            return .calm
        case .paused:
            return AlertState(paused: true)
        case .thermalFair:
            let fcp = apps.first { $0.displayName == "Final Cut Pro" }
            return AlertState(
                level: .elevated, arcs: arcs(.thermals, .elevated), active: [
                    ActiveAlert(kind: .thermalPressure(.fair), level: .elevated, arc: .thermals, since: start,
                                culprit: fcp.map { AppIdentity(key: $0.key, displayName: $0.displayName, bundlePath: $0.bundlePath) },
                                culpritValue: fcp?.baseGPU),
                ]
            )
        case .thermalCritical:
            let fcp = apps.first { $0.displayName == "Final Cut Pro" }
            return AlertState(
                level: .critical, arcs: arcs(.thermals, .critical), active: [
                    ActiveAlert(kind: .thermalPressure(.critical), level: .critical, arc: .thermals, since: start,
                                culprit: fcp.map { AppIdentity(key: $0.key, displayName: $0.displayName, bundlePath: $0.bundlePath) },
                                culpritValue: fcp?.baseGPU),
                ]
            )
        case .memoryWarning:
            let docker = apps.first { $0.pid == 502 }
            return AlertState(
                level: .elevated, arcs: arcs(.memory, .elevated), active: [
                    ActiveAlert(kind: .memoryPressure(.warning), level: .elevated, arc: .memory, since: start,
                                culprit: docker.map { AppIdentity(key: $0.key, displayName: $0.displayName, bundlePath: $0.bundlePath) },
                                culpritValue: docker.map { Double($0.memoryBytes) / 1_073_741_824 }),
                ]
            )
        case .memoryCritical:
            let docker = apps.first { $0.pid == 502 }
            return AlertState(
                level: .critical, arcs: arcs(.memory, .critical), active: [
                    ActiveAlert(kind: .memoryPressure(.critical), level: .critical, arc: .memory, since: start,
                                culprit: docker.map { AppIdentity(key: $0.key, displayName: $0.displayName, bundlePath: $0.bundlePath) },
                                culpritValue: docker.map { Double($0.memoryBytes) / 1_073_741_824 }),
                ]
            )
        case .runaway:
            let xcode = apps.first { $0.displayName == "Xcode" }
            return AlertState(
                level: .elevated, arcs: arcs(.cpu, .elevated), active: [
                    ActiveAlert(kind: .runawayApp(xcode?.key ?? .other, cpuPercent: xcode?.baseCPU ?? 340),
                                level: .elevated, arc: .cpu, since: start.addingTimeInterval(-330),
                                culprit: xcode.map { AppIdentity(key: $0.key, displayName: $0.displayName, bundlePath: $0.bundlePath) },
                                culpritValue: xcode?.baseCPU),
                ]
            )
        case .restricted:
            return .calm
        }
    }

    private func arcs(_ arc: IconArc, _ level: AlertLevel) -> [IconArc: AlertLevel] {
        var a = Dictionary(uniqueKeysWithValues: IconArc.allCases.map { ($0, AlertLevel.calm) })
        a[arc] = level
        return a
    }

    // MARK: - Named app totals

    /// Sums over the named `AppSample`s (before `.other` is added), used to grow each system snapshot to
    /// at least cover them (`makeCPU`/`makeMemory`/`makeNetwork`/`makeDisk`) and then to size `.other`'s
    /// residual in `frame(at:)` — together these make the "sums consistent" invariant hold exactly.
    private struct NamedTotals {
        var cpu, netRx, netTx, diskRead, diskWrite: Double
        var memory: UInt64

        init(_ apps: [AppSample]) {
            cpu = apps.compactMap(\.cpuPercent).reduce(0, +)
            netRx = apps.compactMap(\.netRxBps).reduce(0, +)
            netTx = apps.compactMap(\.netTxBps).reduce(0, +)
            diskRead = apps.compactMap(\.diskReadBps).reduce(0, +)
            diskWrite = apps.compactMap(\.diskWriteBps).reduce(0, +)
            memory = apps.compactMap(\.memory).reduce(0, +)
        }
    }

    // MARK: - Metrics vector

    private func makeMetrics(cpu: CPUSnapshot, gpu: GPUSnapshot, memory: MemorySnapshot, network: NetworkSnapshot,
                              thermals: ThermalSnapshot, power: PowerSnapshot, disk: DiskSnapshot) -> SystemMetrics {
        var m = SystemMetrics()
        m[.cpuUsage] = cpu.usage
        m[.cpuUser] = cpu.user
        m[.cpuSystem] = cpu.system
        m[.cpuPCluster] = cpu.clusters.first { $0.kind == .performance }?.usage
        m[.cpuECluster] = cpu.clusters.first { $0.kind == .efficiency }?.usage
        m[.loadAvg1] = cpu.loadAverage?.first
        m[.gpuUsage] = gpu.usage
        m[.gpuFrequency] = gpu.frequencyMHz
        // NOTE: mapping a `UInt64?` with Double's init (bare, unapplied) is a footgun — it can resolve to
        // the bit-reinterpreting initializer instead of the numeric conversion, giving a denormal
        // ~8e-314. Always use an explicit closure here (ci.sh greps Sources for the bare form).
        m[.memUsed] = memory.used.map { Double($0) }
        m[.memApp] = memory.appMemory.map { Double($0) }
        m[.memWired] = memory.wired.map { Double($0) }
        m[.memCompressed] = memory.compressed.map { Double($0) }
        m[.memPressure] = memory.pressureFraction
        m[.memPressureLevel] = memory.pressureLevel.map { Double($0.rawValue) }     // ICR-12
        m[.swapUsed] = memory.swapUsed.map { Double($0) }
        m[.netRx] = network.rxBps
        m[.netTx] = network.txBps
        m[.netLatency] = network.latency?.lastRTTms
        m[.diskRead] = disk.readBps
        m[.diskWrite] = disk.writeBps
        m[.diskReadIOPS] = disk.readIOPS
        m[.diskWriteIOPS] = disk.writeIOPS
        m[.socTemp] = thermals.socAverage
        m[.cpuPTemp] = thermals.groups.first { $0.group == .cpuPerformance }?.average
        m[.cpuETemp] = thermals.groups.first { $0.group == .cpuEfficiency }?.average
        m[.gpuTemp] = thermals.groups.first { $0.group == .gpu }?.average
        m[.ssdTemp] = thermals.groups.first { $0.group == .ssd }?.average
        m[.batteryTemp] = thermals.groups.first { $0.group == .battery }?.average
        m[.fan1RPM] = thermals.fans.first { $0.id == 0 }?.rpm
        m[.fan2RPM] = thermals.fans.first { $0.id == 1 }?.rpm
        m[.packageWatts] = power.packageWatts
        m[.cpuWatts] = power.cpuWatts
        m[.gpuWatts] = power.gpuWatts
        m[.aneWatts] = power.aneWatts
        m[.dramWatts] = power.dramWatts
        m[.systemWatts] = power.systemWatts
        m[.batteryPercent] = power.battery?.percent
        m[.thermalPressure] = thermals.pressure.map { Double($0.rawValue) }
        return m
    }

    private static func fraction(_ percent: Double) -> Double { percent / 100 }
}
