import Dispatch
import Foundation
import MonitorModel

/// The sampling loop (ARCHITECTURE §3, §4). Runs on its own serial queue (custom executor), owns every sensor
/// (built inside the actor from `SensorFactory`) and the pure assembly/alert state.
///
/// Loop wake-up: each iteration sleeps in a stored `sleeper` task until the next deadline; `setVisibility`,
/// `setPaused`, `systemWillSleep` and `systemDidWake` run while the loop is suspended and cancel the sleeper.
/// Entering interactive (or gaining demand) samples immediately; paused sleeps 1 h (cancellable), takes no samples,
/// yields no records. The engine adds `.memoryAlert` to the demand while the memory arc is ≥ elevated, and
/// connections are collected only in interactive mode (§7: none in background).
public actor SamplingEngine {
    private let queue = DispatchSerialQueue(label: "dev.telltale.sampler", qos: .utility)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// bufferingNewest(1).
    public nonisolated let liveFrames: AsyncStream<SystemFrame>
    /// Unbounded, ~1 element/tick.
    public nonisolated let records: AsyncStream<RecordBatch>
    private let frameContinuation: AsyncStream<SystemFrame>.Continuation
    private let recordContinuation: AsyncStream<RecordBatch>.Continuation

    private let factory: SensorFactory
    private let disabled: Set<SensorID>
    private let canary: CrashCanary
    private let makeResolver: @Sendable () -> any AppResolving
    private let interactiveInterval: Duration
    private let backgroundInterval: Duration
    private let recordBuilder: RecordBuilder

    private var slots: Slots?
    private var assembler: FrameAssembler?
    private var alerts: AlertEngine
    private var episodes: EventDetector
    private var visibility = UIVisibility()
    private var paused = false
    private var sleeping = false
    private var forceSample = true
    private var lastTickNs: UInt64?
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var pauseEvent: HistoryEvent?
    private var sleepEvent: HistoryEvent?

    public init(factory: SensorFactory, disabled: Set<SensorID> = [], alertConfig: AlertConfig = .init(),
                recordConfig: RecordConfig = .init(), canary: CrashCanary = .standard) {
        self.init(factory: factory, disabled: disabled, alertConfig: alertConfig, recordConfig: recordConfig,
                  canary: canary, resolver: { BundleAppResolver() },
                  interactiveInterval: SamplingMode.interactive.interval!, backgroundInterval: SamplingMode.background.interval!)
    }

    /// Test/probe seam: resolver and loop intervals.
    init(factory: SensorFactory, disabled: Set<SensorID> = [], alertConfig: AlertConfig = .init(),
         recordConfig: RecordConfig = .init(), canary: CrashCanary = .none,
         resolver: @escaping @Sendable () -> any AppResolving, interactiveInterval: Duration, backgroundInterval: Duration) {
        self.factory = factory
        self.disabled = disabled
        self.canary = canary
        self.makeResolver = resolver
        self.interactiveInterval = interactiveInterval
        self.backgroundInterval = backgroundInterval
        self.recordBuilder = RecordBuilder(config: recordConfig)
        self.alerts = AlertEngine(config: alertConfig)
        self.episodes = EventDetector()
        (liveFrames, frameContinuation) = AsyncStream.makeStream(of: SystemFrame.self, bufferingPolicy: .bufferingNewest(1))
        (records, recordContinuation) = AsyncStream.makeStream(of: RecordBatch.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Lifecycle

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    /// Stops the loop, closes open episodes into a last record batch and finishes both streams.
    public func stop() async {
        guard let loop else { return }
        loop.cancel()
        sleeper?.cancel()
        await loop.value
        self.loop = nil
        let now = Date()
        var closing = episodes.flush(at: now)
        _ = alerts.setPaused(true, at: now)
        closing += alerts.drainPendingEvents()
        if !closing.isEmpty { recordContinuation.yield(RecordBatch(events: closing)) }
        slots?.invalidateAll()
        frameContinuation.finish()
        recordContinuation.finish()
    }

    public func setVisibility(_ v: UIVisibility) {
        let old = visibility
        visibility = v
        if (v.mode == .interactive && old.mode != .interactive) || !v.demand.isSubset(of: old.demand) {
            forceSample = true
        }
        if v != old { sleeper?.cancel() }
    }

    public func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        let now = Date()
        if paused {
            var events = episodes.flush(at: now)
            _ = alerts.setPaused(true, at: now)
            events += alerts.drainPendingEvents()
            let e = HistoryEvent(kind: .samplingPaused, start: now, level: .calm, label: "Sampling paused")
            pauseEvent = e
            recordContinuation.yield(RecordBatch(events: events + [e]))
        } else {
            _ = alerts.setPaused(false, at: now)
            if var e = pauseEvent {
                e.end = now
                recordContinuation.yield(RecordBatch(events: [e]))
            }
            pauseEvent = nil
            resetBaselines()
            forceSample = true
        }
        sleeper?.cancel()
    }

    public func systemWillSleep() {
        guard !sleeping else { return }
        sleeping = true
        let now = Date()
        var events = episodes.flush(at: now)
        if !paused {
            _ = alerts.setPaused(true, at: now)
            events += alerts.drainPendingEvents()
        }
        let e = HistoryEvent(kind: .systemSleep, start: now, level: .calm, label: "System sleep")
        sleepEvent = e
        recordContinuation.yield(RecordBatch(events: events + [e]))
        sleeper?.cancel()
    }

    public func systemDidWake() {
        let now = Date()
        if sleeping, !paused { _ = alerts.setPaused(false, at: now) }
        sleeping = false
        if var e = sleepEvent {
            e.end = now
            recordContinuation.yield(RecordBatch(events: [e]))
        }
        sleepEvent = nil
        resetBaselines()                                  // first post-wake frame has no rates
        forceSample = true
        sleeper?.cancel()
    }

    // MARK: - One-shot sampling

    public func sampleOnce() -> SystemFrame {
        sampleOnceRaw().frame
    }

    /// telltale-probe --record/--frames: the raw tick and the frame assembled from it.
    public func sampleOnceRaw() -> (tick: RawTick, frame: SystemFrame) {
        let (tick, frame, _) = takeSample(mode: currentMode == .paused ? .interactive : currentMode)
        return (tick, frame)
    }

    /// Per-sensor cost (probe `--bench`).
    public func sensorCosts() -> [SensorID: (last: UInt64, mean: UInt64, p95: UInt64)] {
        slots?.all.reduce(into: [:]) { $0[$1.sensorID] = $1.costNs } ?? [:]
    }

    // MARK: - Loop

    private var currentMode: SamplingMode { paused || sleeping ? .paused : visibility.mode }

    private func interval(_ mode: SamplingMode) -> Duration? {
        switch mode {
        case .interactive: interactiveInterval
        case .background: backgroundInterval
        case .paused: nil
        }
    }

    private func run() async {
        while !Task.isCancelled {
            let mode = currentMode
            var sleepFor = Duration.seconds(3_600)
            if let interval = interval(mode) {
                let now = Self.uptimeNs()
                let intervalNs = UInt64(interval.components.seconds) * 1_000_000_000
                    + UInt64(interval.components.attoseconds / 1_000_000_000)
                let due = forceSample || lastTickNs.map { now >= $0 + intervalNs } ?? true
                if due {
                    forceSample = false
                    let (_, frame, record) = takeSample(mode: mode)
                    frameContinuation.yield(frame)
                    recordContinuation.yield(record)
                    sleepFor = interval
                } else if let last = lastTickNs {
                    sleepFor = .nanoseconds(Int64(last + intervalNs - now))
                }
            }
            let tolerance = sleepFor / 10
            let t = Task { _ = try? await Task.sleep(for: sleepFor, tolerance: tolerance, clock: .continuous) }
            sleeper = t
            await t.value
            sleeper = nil
        }
    }

    // MARK: - Tick

    private func takeSample(mode: SamplingMode) -> (RawTick, SystemFrame, RecordBatch) {
        if slots == nil { slots = Slots(factory.make(disabled), canary: canary) }
        if assembler == nil { assembler = FrameAssembler(resolver: makeResolver()) }

        let now = Self.uptimeNs()
        lastTickNs = now
        let wall = Date()
        var demand = visibility.demand
        if (alerts.state.arcs[.memory] ?? .calm) >= .elevated { demand.insert(.memoryAlert) }
        let ctx = SampleContext(uptimeNs: now, wallTime: wall, mode: mode, demand: demand, alertLevel: alerts.state.level)
        let tick = slots!.sample(ctx)

        let inspected = mode == .interactive ? visibility.inspectedApp : nil
        var frame = assembler!.assemble(tick, inspectedApp: inspected)
        let (state, alertEvents) = alerts.update(thermal: frame.thermals.pressure, memory: frame.memory.pressureLevel,
                                                 apps: frame.apps, at: wall, uptimeNs: now,
                                                 nominalInterval: mode.interval)
        frame.alert = state
        frame.events = alertEvents + episodes.update(frame)
        let record = RecordBatch(record: recordBuilder.record(from: frame), events: frame.events)
        return (tick, frame, record)
    }

    private func resetBaselines() {
        assembler?.reset()
        lastTickNs = nil
    }

    static func uptimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

/// One `SensorSlot` per sensor of the suite; non-Sendable, lives inside the engine actor.
struct Slots {
    let processes: SensorSlot<ProcessTableReading>
    let coalitions: SensorSlot<CoalitionsReading>
    let rootMemory: SensorSlot<RootMemoryReading>
    let hostCPU: SensorSlot<HostCPUReading>
    let memory: SensorSlot<MemoryReading>
    let soc: SensorSlot<SoCPowerReading>
    let gpuClients: SensorSlot<GPUClientsReading>
    let temperatures: SensorSlot<TemperatureReading>
    let smc: SensorSlot<SMCReading>
    let thermalState: SensorSlot<ThermalPressure>
    let networkFlows: SensorSlot<NetworkFlowsReading>
    let interfaces: SensorSlot<InterfacesReading>
    let wifi: SensorSlot<WiFiInfo>
    let latency: SensorSlot<LatencyReading>
    let diskIO: SensorSlot<DiskIOReading>
    let volumes: SensorSlot<VolumesReading>
    let smart: SensorSlot<SMARTInfo>
    let battery: SensorSlot<BatteryReading>
    let sleepAssertions: SensorSlot<SleepAssertionsReading>
    let device: SensorSlot<DeviceInfo>

    init(_ s: SensorSuite, canary: CrashCanary) {
        processes = SensorSlot(s.processes, canary: canary)
        coalitions = SensorSlot(s.coalitions, canary: canary)
        rootMemory = SensorSlot(s.rootMemory, canary: canary)
        hostCPU = SensorSlot(s.hostCPU, canary: canary)
        memory = SensorSlot(s.memory, canary: canary)
        soc = SensorSlot(s.soc, canary: canary)
        gpuClients = SensorSlot(s.gpuClients, canary: canary)
        temperatures = SensorSlot(s.temperatures, canary: canary)
        smc = SensorSlot(s.smc, canary: canary)
        thermalState = SensorSlot(s.thermalState, canary: canary)
        networkFlows = SensorSlot(s.networkFlows, canary: canary)
        interfaces = SensorSlot(s.interfaces, canary: canary)
        wifi = SensorSlot(s.wifi, canary: canary)
        latency = SensorSlot(s.latency, canary: canary)
        diskIO = SensorSlot(s.diskIO, canary: canary)
        volumes = SensorSlot(s.volumes, canary: canary)
        smart = SensorSlot(s.smart, canary: canary)
        battery = SensorSlot(s.battery, canary: canary)
        sleepAssertions = SensorSlot(s.sleepAssertions, canary: canary)
        device = SensorSlot(s.device, canary: canary)
    }

    var all: [any AnySensorSlot] {
        [processes, coalitions, rootMemory, hostCPU, memory, soc, gpuClients, temperatures, smc, thermalState,
         networkFlows, interfaces, wifi, latency, diskIO, volumes, smart, battery, sleepAssertions, device]
    }

    func sample(_ ctx: SampleContext) -> RawTick {
        var t = RawTick(wallTime: ctx.wallTime, uptimeNs: ctx.uptimeNs, mode: ctx.mode, demand: ctx.demand)
        t.processes = processes.sample(ctx)
        t.coalitions = coalitions.sample(ctx)
        t.rootMemory = rootMemory.sample(ctx)
        t.hostCPU = hostCPU.sample(ctx)
        t.memory = memory.sample(ctx)
        t.soc = soc.sample(ctx)
        t.gpuClients = gpuClients.sample(ctx)
        t.temperatures = temperatures.sample(ctx)
        t.smc = smc.sample(ctx)
        t.thermalState = thermalState.sample(ctx)
        t.networkFlows = networkFlows.sample(ctx)
        t.interfaces = interfaces.sample(ctx)
        t.wifi = wifi.sample(ctx)
        t.latency = latency.sample(ctx)
        t.diskIO = diskIO.sample(ctx)
        t.volumes = volumes.sample(ctx)
        t.smart = smart.sample(ctx)
        t.battery = battery.sample(ctx)
        t.sleepAssertions = sleepAssertions.sample(ctx)
        t.device = device.sample(ctx)
        t.health = all.reduce(into: [:]) { $0[$1.sensorID] = $1.status }
        return t
    }

    func invalidateAll() { for s in all { s.invalidate() } }
}
