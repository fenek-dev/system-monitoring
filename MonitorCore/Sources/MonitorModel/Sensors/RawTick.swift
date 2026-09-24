import Foundation

/// One sensor's output for one tick.
public enum SensorResult<R: Sendable & Codable>: Sendable, Codable {
    /// New data.
    case fresh(R, capturedNs: UInt64)
    /// Not due, or an async source whose next result isn't ready.
    case cached(R, capturedNs: UInt64)
    case failed(SensorError, last: R?, capturedNs: UInt64?)
    case notRequested

    public var value: R? {
        switch self {
        case .fresh(let r, _), .cached(let r, _): r
        case .failed(_, let last, _): last
        case .notRequested: nil
        }
    }

    public var capturedNs: UInt64? {
        switch self {
        case .fresh(_, let ns), .cached(_, let ns): ns
        case .failed(_, _, let ns): ns
        case .notRequested: nil
        }
    }
}

/// Everything the sensors produced in one tick; also the fixture format.
public struct RawTick: Sendable, Codable {
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

    public init(
        wallTime: Date = Date(timeIntervalSince1970: 0),
        uptimeNs: UInt64 = 0,
        mode: SamplingMode = .background,
        demand: SamplingDemand = [],
        processes: SensorResult<ProcessTableReading> = .notRequested,
        coalitions: SensorResult<CoalitionsReading> = .notRequested,
        rootMemory: SensorResult<RootMemoryReading> = .notRequested,
        hostCPU: SensorResult<HostCPUReading> = .notRequested,
        memory: SensorResult<MemoryReading> = .notRequested,
        soc: SensorResult<SoCPowerReading> = .notRequested,
        gpuClients: SensorResult<GPUClientsReading> = .notRequested,
        temperatures: SensorResult<TemperatureReading> = .notRequested,
        smc: SensorResult<SMCReading> = .notRequested,
        thermalState: SensorResult<ThermalPressure> = .notRequested,
        networkFlows: SensorResult<NetworkFlowsReading> = .notRequested,
        interfaces: SensorResult<InterfacesReading> = .notRequested,
        wifi: SensorResult<WiFiInfo> = .notRequested,
        latency: SensorResult<LatencyReading> = .notRequested,
        diskIO: SensorResult<DiskIOReading> = .notRequested,
        volumes: SensorResult<VolumesReading> = .notRequested,
        smart: SensorResult<SMARTInfo> = .notRequested,
        battery: SensorResult<BatteryReading> = .notRequested,
        sleepAssertions: SensorResult<SleepAssertionsReading> = .notRequested,
        device: SensorResult<DeviceInfo> = .notRequested,
        health: [SensorID: SensorStatus] = [:]
    ) {
        self.wallTime = wallTime
        self.uptimeNs = uptimeNs
        self.mode = mode
        self.demand = demand
        self.processes = processes
        self.coalitions = coalitions
        self.rootMemory = rootMemory
        self.hostCPU = hostCPU
        self.memory = memory
        self.soc = soc
        self.gpuClients = gpuClients
        self.temperatures = temperatures
        self.smc = smc
        self.thermalState = thermalState
        self.networkFlows = networkFlows
        self.interfaces = interfaces
        self.wifi = wifi
        self.latency = latency
        self.diskIO = diskIO
        self.volumes = volumes
        self.smart = smart
        self.battery = battery
        self.sleepAssertions = sleepAssertions
        self.device = device
        self.health = health
    }

    /// Fixtures stay readable as sensors are added: a missing sensor key decodes as `.notRequested`,
    /// missing `demand` as `[]`, missing `health` as `[:]`. `wallTime`, `uptimeNs` and `mode` are required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func result<R: Sendable & Codable>(_ key: CodingKeys) throws -> SensorResult<R> {
            try c.decodeIfPresent(SensorResult<R>.self, forKey: key) ?? .notRequested
        }
        wallTime = try c.decode(Date.self, forKey: .wallTime)
        uptimeNs = try c.decode(UInt64.self, forKey: .uptimeNs)
        mode = try c.decode(SamplingMode.self, forKey: .mode)
        demand = try c.decodeIfPresent(SamplingDemand.self, forKey: .demand) ?? []
        processes = try result(.processes)
        coalitions = try result(.coalitions)
        rootMemory = try result(.rootMemory)
        hostCPU = try result(.hostCPU)
        memory = try result(.memory)
        soc = try result(.soc)
        gpuClients = try result(.gpuClients)
        temperatures = try result(.temperatures)
        smc = try result(.smc)
        thermalState = try result(.thermalState)
        networkFlows = try result(.networkFlows)
        interfaces = try result(.interfaces)
        wifi = try result(.wifi)
        latency = try result(.latency)
        diskIO = try result(.diskIO)
        volumes = try result(.volumes)
        smart = try result(.smart)
        battery = try result(.battery)
        sleepAssertions = try result(.sleepAssertions)
        device = try result(.device)
        health = try c.decodeIfPresent([SensorID: SensorStatus].self, forKey: .health) ?? [:]
    }
}
