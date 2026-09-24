import Foundation
import MonitorModel
import Observation

// W0b stub (ARCHITECTURE §5.7). W1 replaces this file.

public enum LivePhase: Sendable, Equatable { case collecting(since: Date), live, paused(since: Date) }

@MainActor @Observable
public final class LiveModel {
    public init(device: DeviceInfo = .placeholder, historyCapacity: Int = 300, appHistoryCapacity: Int = 120) {
        self.device = device
        phase = .collecting(since: Date())
    }

    // Always updated (status item)
    public private(set) var alert: AlertState = .calm
    public private(set) var phase: LivePhase
    public private(set) var samplingInterval: Duration?

    // Updated only while isPresenting; each property is assigned only when the new value != old (no spurious invalidation)
    public var isPresenting = false
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
    /// Engine already filtered to the inspected app.
    public private(set) var connections: [ConnectionSample] = []
    public private(set) var sensorHealth: [SensorID: SensorStatus] = [:]
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
    /// Reads the matching counter (tracked).
    public func version(_ c: MonitorModel.Category) -> Int { 0 }

    // Ring buffers are @ObservationIgnored; readers depend on the category counter
    public func series(_ metric: HistoryMetric, window: Duration = .seconds(60)) -> [SeriesPoint] { [] }
    public func appSeries(_ app: AppKey, _ metric: AppMetric, window: Duration = .seconds(60)) -> [SeriesPoint] { [] }

    // Derived; cached per apply (@ObservationIgnored storage, tracked via appsVersion)
    public func topApps(_ category: MonitorModel.Category, count: Int = 3) -> [AppSample] { [] }
    /// Max energyWatts, fallback cpuPercent; excludes .system/.other.
    public var topConsumer: AppSample? { nil }
    public func app(_ key: AppKey) -> AppSample? { nil }
    public func processes(of app: AppKey) -> [ProcessSample] { [] }
    public func status(of sensor: SensorID) -> SensorStatus { .unavailable("not implemented") }

    public func apply(_ frame: SystemFrame) {}
    public func setPaused(_ paused: Bool, at: Date) {}
}
