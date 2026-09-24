import Foundation
import MonitorModel
import Observation

/// Foundation (ObjC runtime) also exports a `Category` type; this module-level alias wins lookup here.
typealias Category = MonitorModel.Category

public enum LivePhase: Sendable, Equatable {
    case collecting(since: Date), live, paused(since: Date)
}

/// UI-facing live state. One `apply` per tick (ARCHITECTURE §5.7, §7):
/// - `alert`, `phase`, `samplingInterval` and the ring buffers always update (status item);
/// - everything else updates only while `isPresenting`, and each property is assigned only when it changed;
/// - per-category version counters let a page depend on one category; ring buffers and derived caches are
///   `@ObservationIgnored` and tracked through those counters.
@MainActor @Observable
public final class LiveModel {
    // Always updated (status item)
    public private(set) var alert: AlertState = .calm
    public private(set) var phase: LivePhase
    public private(set) var samplingInterval: Duration?

    // Updated only while presenting
    public private(set) var device: DeviceInfo
    public private(set) var cpu = CPUSnapshot()
    public private(set) var gpu = GPUSnapshot()
    public private(set) var memory = MemorySnapshot()
    public private(set) var network = NetworkSnapshot()
    public private(set) var thermals = ThermalSnapshot()
    public private(set) var power = PowerSnapshot()
    public private(set) var disk = DiskSnapshot()
    public private(set) var processes: [ProcessSample] = []
    public private(set) var apps: [AppSample] = []
    public private(set) var connections: [ConnectionSample] = []
    public private(set) var sensorHealth: [SensorID: SensorStatus] = [:]
    public private(set) var lastUpdate: Date?

    public private(set) var cpuVersion = 0
    public private(set) var gpuVersion = 0
    public private(set) var memoryVersion = 0
    public private(set) var networkVersion = 0
    public private(set) var thermalsVersion = 0
    public private(set) var powerVersion = 0
    public private(set) var diskVersion = 0
    public private(set) var appsVersion = 0

    private var presenting = false
    /// Bumped (while presenting) whenever the ring buffers got a new point or gap. `series`/`appSeries` read it
    /// in addition to the category counter, so charts scroll even when a category's snapshot is unchanged
    /// (idle disk, constant power), while snapshot observers of that category stay quiet.
    private var seriesVersion = 0

    @ObservationIgnored private var history: LiveHistory
    @ObservationIgnored private var latestFrame: SystemFrame?
    @ObservationIgnored private var topCache: [Category: [AppSample]] = [:]
    @ObservationIgnored private var topConsumerCache: AppSample??
    @ObservationIgnored private var appIndex: [AppKey: Int]?
    @ObservationIgnored private var processesByApp: [AppKey: [ProcessSample]]?

    public init(device: DeviceInfo = .placeholder, historyCapacity: Int = 300, appHistoryCapacity: Int = 120) {
        self.device = device
        self.phase = .collecting(since: Date())
        self.history = LiveHistory(capacity: historyCapacity, appCapacity: appHistoryCapacity, maxTrackedApps: 64)
    }

    /// While false, only `alert`, `phase`, `samplingInterval` and the ring buffers change.
    /// Switching it on applies the latest frame and bumps every counter (the ring buffers moved meanwhile).
    public var isPresenting: Bool {
        get { presenting }
        set {
            guard newValue != presenting else { return }
            presenting = newValue
            if newValue, let f = latestFrame {
                present(f, forceBump: true)
                seriesVersion += 1
            }
        }
    }

    // MARK: - Apply

    public func apply(_ frame: SystemFrame) {
        let appended = history.append(frame)
        latestFrame = frame

        set(\.alert, frame.alert)
        set(\.samplingInterval, frame.mode.interval)
        if frame.interval != nil {
            set(\.phase, .live)
        } else if case .collecting = phase {
            // still collecting: keep `since`
        } else {
            set(\.phase, .collecting(since: frame.wallTime))    // first frame after wake/unpause has no rates
        }

        if presenting {
            present(frame, forceBump: false)
            if appended { seriesVersion += 1 }
        }
    }

    public func setPaused(_ paused: Bool, at: Date) {
        var a = alert
        if paused {
            set(\.phase, .paused(since: at))
            set(\.samplingInterval, nil)
            a = AlertState(pulseToken: alert.pulseToken, paused: true)
            if history.appendGap(at: at), presenting { seriesVersion += 1 }
        } else {
            if case .paused = phase { set(\.phase, .collecting(since: at)) }
            a.paused = false
        }
        set(\.alert, a)
    }

    // MARK: - Reads

    public func version(_ c: MonitorModel.Category) -> Int {
        switch c {
        case .cpu: cpuVersion
        case .gpu: gpuVersion
        case .memory: memoryVersion
        case .network: networkVersion
        case .thermals: thermalsVersion
        case .power: powerVersion
        case .disk: diskVersion
        }
    }

    public func series(_ metric: HistoryMetric, window: Duration = .seconds(60)) -> [SeriesPoint] {
        _ = version(metric.category)
        _ = seriesVersion
        return history.series(metric, window: window)
    }

    public func appSeries(_ app: AppKey, _ metric: AppMetric, window: Duration = .seconds(60)) -> [SeriesPoint] {
        _ = appsVersion
        _ = seriesVersion
        return history.appSeries(app, metric, window: window)
    }

    /// Apps with a positive value for the category's key (ARCHITECTURE §5.5), descending; excludes `.other`.
    public func topApps(_ category: MonitorModel.Category, count: Int = 3) -> [AppSample] {
        _ = appsVersion
        if let cached = topCache[category] { return Array(cached.prefix(count)) }
        let ranked = apps.compactMap { a -> (AppSample, Double)? in
            guard a.identity.key != .other, let v = Self.rankValue(a, category), v > 0 else { return nil }
            return (a, v)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
        topCache[category] = ranked
        return Array(ranked.prefix(count))
    }

    /// Max `energyWatts`; if no app has energy, max `cpuPercent`. Excludes `.system` and `.other`.
    public var topConsumer: AppSample? {
        _ = appsVersion
        if let cached = topConsumerCache { return cached }
        let candidates = apps.filter { $0.identity.key.kind != .system && $0.identity.key.kind != .other }
        let byEnergy = candidates.filter { $0.energyWatts != nil }.max { $0.energyWatts! < $1.energyWatts! }
        let result = byEnergy ?? candidates.filter { $0.cpuPercent != nil }.max { $0.cpuPercent! < $1.cpuPercent! }
        topConsumerCache = .some(result)
        return result
    }

    public func app(_ key: AppKey) -> AppSample? {
        let apps = self.apps
        if appIndex == nil {
            appIndex = Dictionary(apps.enumerated().map { ($1.identity.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return appIndex?[key].map { apps[$0] }
    }

    public func processes(of app: AppKey) -> [ProcessSample] {
        let processes = self.processes
        if processesByApp == nil { processesByApp = Dictionary(grouping: processes, by: \.app) }
        return processesByApp?[app] ?? []
    }

    /// `.ok` when the sensor has reported no status.
    public func status(of sensor: SensorID) -> SensorStatus {
        sensorHealth[sensor] ?? .ok
    }

    // MARK: - Private

    private func present(_ f: SystemFrame, forceBump: Bool) {
        set(\.device, f.device)
        if set(\.cpu, f.cpu) || forceBump { cpuVersion += 1 }
        if set(\.gpu, f.gpu) || forceBump { gpuVersion += 1 }
        if set(\.memory, f.memory) || forceBump { memoryVersion += 1 }
        if set(\.network, f.network) || forceBump { networkVersion += 1 }
        if set(\.thermals, f.thermals) || forceBump { thermalsVersion += 1 }
        if set(\.power, f.power) || forceBump { powerVersion += 1 }
        if set(\.disk, f.disk) || forceBump { diskVersion += 1 }
        let processesChanged = set(\.processes, f.processes)
        let appsChanged = set(\.apps, f.apps)
        if processesChanged { processesByApp = nil }
        if appsChanged {
            topCache.removeAll(keepingCapacity: true)
            topConsumerCache = nil
            appIndex = nil
        }
        if processesChanged || appsChanged || forceBump { appsVersion += 1 }
        set(\.connections, f.connections)
        set(\.sensorHealth, f.sensorHealth)
        set(\.lastUpdate, f.wallTime)
    }

    /// Assigns only when the value changed; returns whether it did.
    @discardableResult
    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<LiveModel, T>, _ value: T) -> Bool {
        guard self[keyPath: kp] != value else { return false }
        self[keyPath: kp] = value
        return true
    }

    private static func rankValue(_ a: AppSample, _ category: Category) -> Double? {
        switch category {
        case .cpu: a.cpuPercent
        case .gpu: a.gpuPercent
        case .memory: a.memory.map { Double($0) }
        case .network: sum(a.netRxBps, a.netTxBps)
        case .thermals, .power: a.energyWatts
        case .disk: sum(a.diskReadBps, a.diskWriteBps)
        }
    }

    private static func sum(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): nil
        default: (a ?? 0) + (b ?? 0)
        }
    }
}

extension HistoryMetric {
    /// Category whose version counter tracks this metric's live series.
    public var category: MonitorModel.Category {
        switch self {
        case .cpuUsage, .cpuUser, .cpuSystem, .cpuPCluster, .cpuECluster, .loadAvg1: .cpu
        case .gpuUsage, .gpuFrequency: .gpu
        case .memUsed, .memApp, .memWired, .memCompressed, .memPressure, .swapUsed: .memory
        case .netRx, .netTx, .netLatency: .network
        case .diskRead, .diskWrite, .diskReadIOPS, .diskWriteIOPS: .disk
        case .socTemp, .cpuPTemp, .cpuETemp, .gpuTemp, .ssdTemp, .batteryTemp, .fan1RPM, .fan2RPM, .thermalPressure:
            .thermals
        case .packageWatts, .cpuWatts, .gpuWatts, .aneWatts, .dramWatts, .systemWatts, .batteryPercent: .power
        }
    }
}
