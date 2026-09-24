import Foundation

public struct TemperatureGroupSnapshot: Sendable, Codable, Hashable {
    public var group: TemperatureGroup, average: Double, maximum: Double, sensorCount: Int

    public init(group: TemperatureGroup = .other, average: Double = 0, maximum: Double = 0, sensorCount: Int = 0) {
        self.group = group
        self.average = average
        self.maximum = maximum
        self.sensorCount = sensorCount
    }
}

public struct FanSnapshot: Sendable, Codable, Hashable, Identifiable {
    public var id: Int, name: String, rpm, minRPM, maxRPM: Double

    public init(id: Int = 0, name: String = "", rpm: Double = 0, minRPM: Double = 0, maxRPM: Double = 0) {
        self.id = id
        self.name = name
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

public struct ThermalSnapshot: Sendable, Codable, Equatable {
    public var pressure: ThermalPressure?
    public var socAverage: Double?, hottest: RawTemperature?
    /// From SMC catalog keys (always).
    public var groups: [TemperatureGroupSnapshot]
    /// HID + SMC raw list, only with `.rawTemperatures`.
    public var sensors: [RawTemperature]
    /// Read-only (ruling).
    public var fans: [FanSnapshot]
    /// True when hw.model is not in the catalog (generic families).
    public var approximateMapping: Bool

    public init(
        pressure: ThermalPressure? = nil,
        socAverage: Double? = nil,
        hottest: RawTemperature? = nil,
        groups: [TemperatureGroupSnapshot] = [],
        sensors: [RawTemperature] = [],
        fans: [FanSnapshot] = [],
        approximateMapping: Bool = false
    ) {
        self.pressure = pressure
        self.socAverage = socAverage
        self.hottest = hottest
        self.groups = groups
        self.sensors = sensors
        self.fans = fans
        self.approximateMapping = approximateMapping
    }
}
