import Foundation

public enum TemperatureGroup: String, CaseIterable, Sendable, Codable {
    case cpuPerformance, cpuEfficiency, gpu, soc, ssd, battery, airflow, other
}

public struct RawTemperature: Sendable, Codable, Hashable {
    public var name: String, celsius: Double, group: TemperatureGroup, source: Source

    public enum Source: String, Sendable, Codable { case hid, smc }

    public init(name: String = "", celsius: Double = 0, group: TemperatureGroup = .other, source: Source = .smc) {
        self.name = name
        self.celsius = celsius
        self.group = group
        self.source = source
    }
}

/// HID raw list.
public struct TemperatureReading: Sendable, Codable {
    public var sensors: [RawTemperature]

    public init(sensors: [RawTemperature] = []) {
        self.sensors = sensors
    }
}

public enum ThermalPressure: Int, Sendable, Codable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
