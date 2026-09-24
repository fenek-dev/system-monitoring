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
    private let overlayInterval: Duration
    /// Sample clock for tick contexts (test seam); the loop's deadlines always use the real uptime.
    private let uptime: @Sendable () -> UInt64
    private let recordBuilder: RecordBuilder

    private var slots: Slots?
    private var assembler: FrameAssembler?
    private var alerts: AlertEngine
    private var episodes: EventDetector
    private var visibility = UIVisibility()
    private var paused = false
    private var sleeping = false
    private var forceSample = true
    /// Next scheduled tick on the uptime grid (deadline-based: no drift; overruns skip to the next slot).
    private var nextDeadlineNs: UInt64?
    /// Sample-clock time of the last emitted record (any mode); nil after a baseline reset. Paces overlay records.
    private var lastRecordNs: UInt64?
    private var stopped = false
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var pauseEvent: HistoryEvent?
    private var sleepEvent: HistoryEvent?

    public init(factory: SensorFactory, disabled: Set<SensorID> = [], alertConfig: AlertConfig = .init(),
                recordConfig: RecordConfig = .init(), canary: CrashCanary = .standard) {
        self.init(factory: factory, disabled: disabled, alertConfig: alertConfig, recordConfig: recordConfig,
                  canary: canary, resolver: { BundleAppResolver() },
                  interactiveInterval: SamplingMode.interactive.interval!, backgroundInterval: SamplingMode.background.interval!,
                  overlayInterval: SamplingMode.overlay.interval!)
    }

    /// Test/probe seam: resolver, loop intervals and the sample clock.
    init(factory: SensorFactory, disabled: Set<SensorID> = [], alertConfig: AlertConfig = .init(),
         recordConfig: RecordConfig = .init(), canary: CrashCanary = .none,
         resolver: @escaping @Sendable () -> any AppResolving, interactiveInterval: Duration, backgroundInterval: Duration,
         overlayInterval: Duration = .seconds(1), uptime: @escaping @Sendable () -> UInt64 = { SamplingEngine.uptimeNs() }) {
        self.uptime = uptime
        self.factory = factory
        self.disabled = disabled
        self.canary = canary
        self.makeResolver = resolver
        self.interactiveInterval = interactiveInterval
        self.backgroundInterval = backgroundInterval
        self.overlayInterval = overlayInterval
        self.recordBuilder = RecordBuilder(config: recordConfig)
        self.alerts = AlertEngine(config: alertConfig)
        self.episodes = EventDetector()
        (liveFrames, frameContinuation) = AsyncStream.makeStream(of: SystemFrame.self, bufferingPolicy: .bufferingNewest(1))
        (records, recordContinuation) = AsyncStream.makeStream(of: RecordBatch.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Lifecycle

    /// No-op when already running or after `stop()` (the streams are finished then).
    public func start() {
        guard loop == nil, !stopped else { return }
        loop = Task { await self.run() }
    }

    /// Stops the loop (if running), closes open episodes and pause/sleep markers into a last record batch,
    /// invalidates the sensors and finishes both streams. Final: a later `start()` does nothing.
    public func stop() async {
        guard !stopped else { return }
        stopped = true
        if let loop {
            loop.cancel()
            sleeper?.cancel()
            await loop.value
            self.loop = nil
        }
        let now = Date()
        var closing = episodes.flush(at: now)
        _ = alerts.setPaused(true, at: now)
        closing += alerts.drainPendingEvents()
        for var marker in [pauseEvent, sleepEvent].compactMap({ $0 }) {
            marker.end = now
            closing.append(marker)
        }
        pauseEvent = nil
        sleepEvent = nil
        if !closing.isEmpty { recordContinuation.yield(RecordBatch(events: closing)) }
        slots?.invalidateAll()
        frameContinuation.finish()
        recordContinuation.finish()
    }

    public func setVisibility(_ v: UIVisibility) {
        let old = visibility
        visibility = v
        // Any move to a faster mode (interactive, or overlay from background) samples at once.
        if (v.mode != old.mode && v.mode != .background) || !v.demand.isSubset(of: old.demand) {
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

    /// Test hook: one tick in the current mode, with the record batch the loop would yield.
    func sampleOnceBatch() -> (frame: SystemFrame, batch: RecordBatch) {
        let (_, frame, batch) = takeSample(mode: currentMode == .paused ? .interactive : currentMode)
        return (frame, batch)
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
        case .overlay: overlayInterval
        }
    }

    private func run() async {
        while !Task.isCancelled {
            let mode = currentMode
            var sleepFor = Duration.seconds(3_600)
            var tolerance = sleepFor / 10
            if let interval = interval(mode), let intervalNs = SensorSlot<Int>.ns(interval), intervalNs > 0 {
                let now = Self.uptimeNs()
                if forceSample || nextDeadlineNs.map({ now >= $0 }) ?? true {
                    // Grid origin: the missed deadline (keeps the cadence), or now when forced / first.
                    let base = forceSample ? now : (nextDeadlineNs ?? now)
                    forceSample = false
                    let (_, frame, record) = takeSample(mode: mode)
                    frameContinuation.yield(frame)
                    recordContinuation.yield(record)
                    let after = Self.uptimeNs()
                    var next = base + intervalNs
                    if next <= after { next += ((after - next) / intervalNs + 1) * intervalNs }   // overrun: next slot
                    nextDeadlineNs = next
                }
                let wake = Self.uptimeNs()
                let target = nextDeadlineNs ?? wake
                sleepFor = .nanoseconds(Int64(target > wake ? target - wake : 0))
                tolerance = interval / 10
            }
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

        let now = uptime()
        let wall = Date()
        var demand = visibility.demand
        if (alerts.state.arcs[.memory] ?? .calm) >= .elevated { demand.insert(.memoryAlert) }
        let ctx = SampleContext(uptimeNs: now, wallTime: wall, mode: mode, demand: demand, alertLevel: alerts.state.level)
        let tick = slots!.sample(ctx)

        let inspected = mode == .interactive ? visibility.inspectedApp : nil
        var frame = assembler!.assemble(tick, inspectedApp: inspected)
        let (state, alertEvents) = alerts.update(thermal: frame.thermals.pressure, memory: frame.memory.pressureLevel,
                                                 apps: frame.apps, at: wall, uptimeNs: now,
                                                 nominalInterval: interval(mode))
        frame.alert = state
        frame.events = alertEvents + episodes.update(frame)
        let record: HistoryRecord?
        if mode == .overlay {
            record = overlayRecordDue(now: now, processesFresh: tick.processes.isFresh, mode: mode)
                ? recordBuilder.record(from: frame, interval: SamplingMode.background.interval) : nil
        } else {
            record = recordBuilder.record(from: frame)
        }
        if record != nil { lastRecordNs = now }
        let batch = RecordBatch(record: record, events: frame.events)
        return (tick, frame, batch)
    }

    /// Overlay (R3): history volume matches background mode — one record per ~5 s, independent of the process
    /// sensor. A record is due at `since ≥ 5 s − tick/2` and taken on a tick where the process table was fresh
    /// (aligned with its 5-s cadence); at `since ≥ 5 s + tick` it is overdue and taken regardless (failing,
    /// backing-off or disabled process sensor). Each overlay row stores ONE 1-s sample weighted as 5 s
    /// (`interval_ms` = 5000) — accepted ruling: rollups treat it as covering the 5 s since the previous row.
    private func overlayRecordDue(now: UInt64, processesFresh: Bool, mode: SamplingMode) -> Bool {
        guard let last = lastRecordNs, now > last else { return lastRecordNs == nil }
        let since = now - last                                        // guarded: now > last
        let period = SensorSlot<Int>.ns(SamplingMode.background.interval) ?? 5_000_000_000
        let tick = SensorSlot<Int>.ns(mode.interval) ?? 1_000_000_000
        let due = since >= period - min(tick / 2, period)
        let overdue = since >= period + tick
        return (due && processesFresh) || overdue
    }

    private func resetBaselines() {
        assembler?.reset()
        nextDeadlineNs = nil
        lastRecordNs = nil
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
        all = [processes, coalitions, rootMemory, hostCPU, memory, soc, gpuClients, temperatures, smc, thermalState,
               networkFlows, interfaces, wifi, latency, diskIO, volumes, smart, battery, sleepAssertions, device]
    }

    /// Every slot, built once.
    let all: [any AnySensorSlot]

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
