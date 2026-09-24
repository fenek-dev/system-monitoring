import MonitorModel

/// Production sensor wiring: one adapter per `SensorID` (ARCHITECTURE §2, §5.4).
/// A sensor in `disabled` is never constructed; its slot gets an `UnavailableSensor`.
public extension SensorFactory {
    static let live = SensorFactory { disabled in
        func pick<R: Sendable & Codable>(_ id: SensorID, _ make: () -> any Sensor<R>) -> any Sensor<R> {
            disabled.contains(id) ? UnavailableSensor<R>(id, reason: SensorFactory.disabledReason) : make()
        }
        return SensorSuite(
            processes: pick(.processes) { ProcessTableSensor() },
            coalitions: pick(.coalitions) { CoalitionSensor() },
            rootMemory: pick(.rootMemory) { RootMemorySensor() },
            hostCPU: pick(.hostCPU) { HostCPUSensor() },
            memory: pick(.memory) { MemorySensor() },
            soc: pick(.soc) { IOReportSensor() },
            gpuClients: pick(.gpuClients) { GPUClientsSensor() },
            temperatures: pick(.temperatures) { HIDTemperatureSensor() },
            smc: pick(.smc) { SMCSensor() },
            thermalState: pick(.thermalState) { ThermalStateSensor() },
            networkFlows: pick(.networkFlows) { NStatSensor() },
            interfaces: pick(.interfaces) { InterfaceSensor() },
            wifi: pick(.wifi) { WiFiSensor() },
            latency: pick(.latency) { LatencyProbe() },
            diskIO: pick(.diskIO) { DiskIOSensor() },
            volumes: pick(.volumes) { VolumeSensor() },
            smart: pick(.smart) { SMARTSensor() },
            battery: pick(.battery) { BatterySensor() },
            sleepAssertions: pick(.sleepAssertions) { SleepAssertionSensor() },
            device: pick(.device) { DeviceInfoSensor() }
        )
    }

    /// Reason carried by the placeholder of a user-disabled sensor.
    static let disabledReason = "Disabled in Settings"
}
