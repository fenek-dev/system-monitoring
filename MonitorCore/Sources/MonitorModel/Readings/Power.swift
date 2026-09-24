import Foundation

/// AppleSmartBattery ioreg preferred (findings).
public struct BatteryReading: Sendable, Codable, Equatable {
    public var present: Bool, percent: Double?, isCharging: Bool, onAC: Bool
    public var minutesToEmpty: Int?, minutesToFull: Int?, cycleCount: Int?
    public var designCapacityWh: Double?, maxCapacityWh: Double?, currentCapacityWh: Double?
    public var voltageV: Double?, amperageA: Double?, temperatureC: Double?, condition: String?
    public var adapterName: String?, lowPowerMode: Bool

    public init(
        present: Bool = false,
        percent: Double? = nil,
        isCharging: Bool = false,
        onAC: Bool = false,
        minutesToEmpty: Int? = nil,
        minutesToFull: Int? = nil,
        cycleCount: Int? = nil,
        designCapacityWh: Double? = nil,
        maxCapacityWh: Double? = nil,
        currentCapacityWh: Double? = nil,
        voltageV: Double? = nil,
        amperageA: Double? = nil,
        temperatureC: Double? = nil,
        condition: String? = nil,
        adapterName: String? = nil,
        lowPowerMode: Bool = false
    ) {
        self.present = present
        self.percent = percent
        self.isCharging = isCharging
        self.onAC = onAC
        self.minutesToEmpty = minutesToEmpty
        self.minutesToFull = minutesToFull
        self.cycleCount = cycleCount
        self.designCapacityWh = designCapacityWh
        self.maxCapacityWh = maxCapacityWh
        self.currentCapacityWh = currentCapacityWh
        self.voltageV = voltageV
        self.amperageA = amperageA
        self.temperatureC = temperatureC
        self.condition = condition
        self.adapterName = adapterName
        self.lowPowerMode = lowPowerMode
    }
}

public struct SleepAssertionsReading: Sendable, Codable {
    public var byPID: [Int32: [String]]

    public init(byPID: [Int32: [String]] = [:]) {
        self.byPID = byPID
    }
}
