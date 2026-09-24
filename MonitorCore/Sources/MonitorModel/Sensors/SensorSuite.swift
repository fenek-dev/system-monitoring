import Foundation

/// One sensor per `SensorID`. Non-Sendable; built and owned inside `SamplingEngine`.
public struct SensorSuite {
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

    /// Every omitted sensor is an `UnavailableSensor` ("Not configured").
    public init(
        processes: any Sensor<ProcessTableReading> = UnavailableSensor<ProcessTableReading>(.processes, reason: notConfigured),
        coalitions: any Sensor<CoalitionsReading> = UnavailableSensor<CoalitionsReading>(.coalitions, reason: notConfigured),
        rootMemory: any Sensor<RootMemoryReading> = UnavailableSensor<RootMemoryReading>(.rootMemory, reason: notConfigured),
        hostCPU: any Sensor<HostCPUReading> = UnavailableSensor<HostCPUReading>(.hostCPU, reason: notConfigured),
        memory: any Sensor<MemoryReading> = UnavailableSensor<MemoryReading>(.memory, reason: notConfigured),
        soc: any Sensor<SoCPowerReading> = UnavailableSensor<SoCPowerReading>(.soc, reason: notConfigured),
        gpuClients: any Sensor<GPUClientsReading> = UnavailableSensor<GPUClientsReading>(.gpuClients, reason: notConfigured),
        temperatures: any Sensor<TemperatureReading> =
            UnavailableSensor<TemperatureReading>(.temperatures, reason: notConfigured),
        smc: any Sensor<SMCReading> = UnavailableSensor<SMCReading>(.smc, reason: notConfigured),
        thermalState: any Sensor<ThermalPressure> = UnavailableSensor<ThermalPressure>(.thermalState, reason: notConfigured),
        networkFlows: any Sensor<NetworkFlowsReading> =
            UnavailableSensor<NetworkFlowsReading>(.networkFlows, reason: notConfigured),
        interfaces: any Sensor<InterfacesReading> = UnavailableSensor<InterfacesReading>(.interfaces, reason: notConfigured),
        wifi: any Sensor<WiFiInfo> = UnavailableSensor<WiFiInfo>(.wifi, reason: notConfigured),
        latency: any Sensor<LatencyReading> = UnavailableSensor<LatencyReading>(.latency, reason: notConfigured),
        diskIO: any Sensor<DiskIOReading> = UnavailableSensor<DiskIOReading>(.diskIO, reason: notConfigured),
        volumes: any Sensor<VolumesReading> = UnavailableSensor<VolumesReading>(.volumes, reason: notConfigured),
        smart: any Sensor<SMARTInfo> = UnavailableSensor<SMARTInfo>(.smart, reason: notConfigured),
        battery: any Sensor<BatteryReading> = UnavailableSensor<BatteryReading>(.battery, reason: notConfigured),
        sleepAssertions: any Sensor<SleepAssertionsReading> =
            UnavailableSensor<SleepAssertionsReading>(.sleepAssertions, reason: notConfigured),
        device: any Sensor<DeviceInfo> = UnavailableSensor<DeviceInfo>(.device, reason: notConfigured)
    ) {
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
    }

    public static let notConfigured = "Not configured"

    /// Every sensor an `UnavailableSensor` with `reason`.
    public static func allUnavailable(reason: String) -> SensorSuite {
        SensorSuite(
            processes: UnavailableSensor<ProcessTableReading>(.processes, reason: reason),
            coalitions: UnavailableSensor<CoalitionsReading>(.coalitions, reason: reason),
            rootMemory: UnavailableSensor<RootMemoryReading>(.rootMemory, reason: reason),
            hostCPU: UnavailableSensor<HostCPUReading>(.hostCPU, reason: reason),
            memory: UnavailableSensor<MemoryReading>(.memory, reason: reason),
            soc: UnavailableSensor<SoCPowerReading>(.soc, reason: reason),
            gpuClients: UnavailableSensor<GPUClientsReading>(.gpuClients, reason: reason),
            temperatures: UnavailableSensor<TemperatureReading>(.temperatures, reason: reason),
            smc: UnavailableSensor<SMCReading>(.smc, reason: reason),
            thermalState: UnavailableSensor<ThermalPressure>(.thermalState, reason: reason),
            networkFlows: UnavailableSensor<NetworkFlowsReading>(.networkFlows, reason: reason),
            interfaces: UnavailableSensor<InterfacesReading>(.interfaces, reason: reason),
            wifi: UnavailableSensor<WiFiInfo>(.wifi, reason: reason),
            latency: UnavailableSensor<LatencyReading>(.latency, reason: reason),
            diskIO: UnavailableSensor<DiskIOReading>(.diskIO, reason: reason),
            volumes: UnavailableSensor<VolumesReading>(.volumes, reason: reason),
            smart: UnavailableSensor<SMARTInfo>(.smart, reason: reason),
            battery: UnavailableSensor<BatteryReading>(.battery, reason: reason),
            sleepAssertions: UnavailableSensor<SleepAssertionsReading>(.sleepAssertions, reason: reason),
            device: UnavailableSensor<DeviceInfo>(.device, reason: reason)
        )
    }

    /// Wraps that field in `CrashingSensor` (crash canary drill).
    public func crashing(_ id: SensorID) -> SensorSuite {
        var s = self
        switch id {
        case .processes: s.processes = CrashingSensor(wrapping: processes)
        case .coalitions: s.coalitions = CrashingSensor(wrapping: coalitions)
        case .rootMemory: s.rootMemory = CrashingSensor(wrapping: rootMemory)
        case .hostCPU: s.hostCPU = CrashingSensor(wrapping: hostCPU)
        case .memory: s.memory = CrashingSensor(wrapping: memory)
        case .soc: s.soc = CrashingSensor(wrapping: soc)
        case .gpuClients: s.gpuClients = CrashingSensor(wrapping: gpuClients)
        case .temperatures: s.temperatures = CrashingSensor(wrapping: temperatures)
        case .smc: s.smc = CrashingSensor(wrapping: smc)
        case .thermalState: s.thermalState = CrashingSensor(wrapping: thermalState)
        case .networkFlows: s.networkFlows = CrashingSensor(wrapping: networkFlows)
        case .interfaces: s.interfaces = CrashingSensor(wrapping: interfaces)
        case .wifi: s.wifi = CrashingSensor(wrapping: wifi)
        case .latency: s.latency = CrashingSensor(wrapping: latency)
        case .diskIO: s.diskIO = CrashingSensor(wrapping: diskIO)
        case .volumes: s.volumes = CrashingSensor(wrapping: volumes)
        case .smart: s.smart = CrashingSensor(wrapping: smart)
        case .battery: s.battery = CrashingSensor(wrapping: battery)
        case .sleepAssertions: s.sleepAssertions = CrashingSensor(wrapping: sleepAssertions)
        case .device: s.device = CrashingSensor(wrapping: device)
        }
        return s
    }
}

public struct SensorFactory: Sendable {
    public var make: @Sendable (_ disabled: Set<SensorID>) -> SensorSuite

    public init(make: @escaping @Sendable (Set<SensorID>) -> SensorSuite) {
        self.make = make
    }

    /// `--crash-sensor <id>` (DEBUG builds; parsed by AppEnvironment, passed through TelltaleRuntime.make) → canary drill.
    /// nil → self.
    public func crashing(_ id: SensorID?) -> SensorFactory {
        guard let id else { return self }
        let make = self.make
        return SensorFactory { disabled in make(disabled).crashing(id) }
    }
}
// MonitorSensors/LiveSensorFactory.swift: public extension SensorFactory { static let live: SensorFactory }
