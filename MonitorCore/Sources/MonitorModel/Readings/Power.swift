import Foundation

/// AppleSmartBattery ioreg preferred (findings).
public struct BatteryReading: Sendable, Codable, Equatable {
    public var present: Bool, percent: Double?, isCharging: Bool, onAC: Bool
    public var minutesToEmpty: Int?, minutesToFull: Int?, cycleCount: Int?
    public var designCapacityWh: Double?, maxCapacityWh: Double?, currentCapacityWh: Double?
    public var voltageV: Double?, amperageA: Double?, temperatureC: Double?, condition: String?
    public var adapterName: String?, lowPowerMode: Bool
    /// True while macOS is still estimating time remaining (IOPS −1 / registry 65535 in the relevant field):
    /// the UI shows "Calculating…" instead of "—". `minutesToEmpty/Full` are nil then. Additive (W6b ruling),
    /// decoded with `decodeIfPresent` (older fixtures → false).
    public var timeRemainingCalculating: Bool

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
        lowPowerMode: Bool = false,
        timeRemainingCalculating: Bool = false
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
        self.timeRemainingCalculating = timeRemainingCalculating
    }

    private enum CodingKeys: String, CodingKey {
        case present, percent, isCharging, onAC, minutesToEmpty, minutesToFull, cycleCount
        case designCapacityWh, maxCapacityWh, currentCapacityWh, voltageV, amperageA, temperatureC, condition
        case adapterName, lowPowerMode, timeRemainingCalculating
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        present = try c.decode(Bool.self, forKey: .present)
        percent = try c.decodeIfPresent(Double.self, forKey: .percent)
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        onAC = try c.decode(Bool.self, forKey: .onAC)
        minutesToEmpty = try c.decodeIfPresent(Int.self, forKey: .minutesToEmpty)
        minutesToFull = try c.decodeIfPresent(Int.self, forKey: .minutesToFull)
        cycleCount = try c.decodeIfPresent(Int.self, forKey: .cycleCount)
        designCapacityWh = try c.decodeIfPresent(Double.self, forKey: .designCapacityWh)
        maxCapacityWh = try c.decodeIfPresent(Double.self, forKey: .maxCapacityWh)
        currentCapacityWh = try c.decodeIfPresent(Double.self, forKey: .currentCapacityWh)
        voltageV = try c.decodeIfPresent(Double.self, forKey: .voltageV)
        amperageA = try c.decodeIfPresent(Double.self, forKey: .amperageA)
        temperatureC = try c.decodeIfPresent(Double.self, forKey: .temperatureC)
        condition = try c.decodeIfPresent(String.self, forKey: .condition)
        adapterName = try c.decodeIfPresent(String.self, forKey: .adapterName)
        lowPowerMode = try c.decode(Bool.self, forKey: .lowPowerMode)
        timeRemainingCalculating = try c.decodeIfPresent(Bool.self, forKey: .timeRemainingCalculating) ?? false
    }
}

public struct SleepAssertionsReading: Sendable, Codable {
    public var byPID: [Int32: [String]]

    public init(byPID: [Int32: [String]] = [:]) {
        self.byPID = byPID
    }
}
