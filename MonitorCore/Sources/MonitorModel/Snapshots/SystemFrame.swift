import Foundation

public struct SystemFrame: Sendable, Codable, Equatable {
    public var wallTime: Date, uptimeNs: UInt64, interval: Duration?, mode: SamplingMode
    public var device: DeviceInfo
    public var cpu: CPUSnapshot, gpu: GPUSnapshot, memory: MemorySnapshot, network: NetworkSnapshot
    public var thermals: ThermalSnapshot, power: PowerSnapshot, disk: DiskSnapshot
    /// Incl. synthetic coalition rows; unsorted.
    public var processes: [ProcessSample]
    /// Sorted by cpuPercent desc.
    public var apps: [AppSample]
    /// Only for `UIVisibility.inspectedApp`.
    public var connections: [ConnectionSample]
    public var alert: AlertState
    public var events: [HistoryEvent]
    public var sensorHealth: [SensorID: SensorStatus]
    public var metrics: SystemMetrics

    public init(
        wallTime: Date = Date(timeIntervalSince1970: 0),
        uptimeNs: UInt64 = 0,
        interval: Duration? = nil,
        mode: SamplingMode = .background,
        device: DeviceInfo = .placeholder,
        cpu: CPUSnapshot = CPUSnapshot(),
        gpu: GPUSnapshot = GPUSnapshot(),
        memory: MemorySnapshot = MemorySnapshot(),
        network: NetworkSnapshot = NetworkSnapshot(),
        thermals: ThermalSnapshot = ThermalSnapshot(),
        power: PowerSnapshot = PowerSnapshot(),
        disk: DiskSnapshot = DiskSnapshot(),
        processes: [ProcessSample] = [],
        apps: [AppSample] = [],
        connections: [ConnectionSample] = [],
        alert: AlertState = .calm,
        events: [HistoryEvent] = [],
        sensorHealth: [SensorID: SensorStatus] = [:],
        metrics: SystemMetrics = SystemMetrics()
    ) {
        self.wallTime = wallTime
        self.uptimeNs = uptimeNs
        self.interval = interval
        self.mode = mode
        self.device = device
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.network = network
        self.thermals = thermals
        self.power = power
        self.disk = disk
        self.processes = processes
        self.apps = apps
        self.connections = connections
        self.alert = alert
        self.events = events
        self.sensorHealth = sensorHealth
        self.metrics = metrics
    }

    /// No data: placeholder device, empty snapshots, calm alert state.
    public static let empty = SystemFrame()
}
