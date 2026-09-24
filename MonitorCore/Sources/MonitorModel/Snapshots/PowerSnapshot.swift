import Foundation

public struct BatterySnapshot: Sendable, Codable, Equatable {
    public var percent: Double?, isCharging: Bool, onAC: Bool, timeRemaining: Duration?
    public var healthFraction: Double?, cycleCount: Int?, condition: String?
    public var maxCapacityWh: Double?, designCapacityWh: Double?, currentCapacityWh: Double?
    public var temperatureC: Double?
    /// Battery power, signed V × A (ruling): negative while discharging ("−18.9 W"), positive while charging ("+W").
    public var drainWatts: Double?
    /// macOS is still estimating the time remaining (`timeRemaining` nil): UI shows "Calculating…", not "—".
    /// Additive (battery ruling); absent in older encodings → false.
    public var timeRemainingCalculating: Bool

    public init(
        percent: Double? = nil,
        isCharging: Bool = false,
        onAC: Bool = false,
        timeRemaining: Duration? = nil,
        healthFraction: Double? = nil,
        cycleCount: Int? = nil,
        condition: String? = nil,
        maxCapacityWh: Double? = nil,
        designCapacityWh: Double? = nil,
        currentCapacityWh: Double? = nil,
        temperatureC: Double? = nil,
        drainWatts: Double? = nil,
        timeRemainingCalculating: Bool = false
    ) {
        self.timeRemainingCalculating = timeRemainingCalculating
        self.percent = percent
        self.isCharging = isCharging
        self.onAC = onAC
        self.timeRemaining = timeRemaining
        self.healthFraction = healthFraction
        self.cycleCount = cycleCount
        self.condition = condition
        self.maxCapacityWh = maxCapacityWh
        self.designCapacityWh = designCapacityWh
        self.currentCapacityWh = currentCapacityWh
        self.temperatureC = temperatureC
        self.drainWatts = drainWatts
    }

    /// Hand-written (for `timeRemainingCalculating`'s decodeIfPresent): every NEW stored property must be added here
    /// and to `init(from:)`, or it silently won't encode/decode.
    private enum CodingKeys: String, CodingKey {
        case percent, isCharging, onAC, timeRemaining, healthFraction, cycleCount, condition
        case maxCapacityWh, designCapacityWh, currentCapacityWh, temperatureC, drainWatts, timeRemainingCalculating
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percent = try c.decodeIfPresent(Double.self, forKey: .percent)
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        onAC = try c.decode(Bool.self, forKey: .onAC)
        timeRemaining = try c.decodeIfPresent(Duration.self, forKey: .timeRemaining)
        healthFraction = try c.decodeIfPresent(Double.self, forKey: .healthFraction)
        cycleCount = try c.decodeIfPresent(Int.self, forKey: .cycleCount)
        condition = try c.decodeIfPresent(String.self, forKey: .condition)
        maxCapacityWh = try c.decodeIfPresent(Double.self, forKey: .maxCapacityWh)
        designCapacityWh = try c.decodeIfPresent(Double.self, forKey: .designCapacityWh)
        currentCapacityWh = try c.decodeIfPresent(Double.self, forKey: .currentCapacityWh)
        temperatureC = try c.decodeIfPresent(Double.self, forKey: .temperatureC)
        drainWatts = try c.decodeIfPresent(Double.self, forKey: .drainWatts)
        timeRemainingCalculating = try c.decodeIfPresent(Bool.self, forKey: .timeRemainingCalculating) ?? false
    }
}

public struct PowerSnapshot: Sendable, Codable, Equatable {
    public var packageWatts: Double?, cpuWatts: Double?, gpuWatts: Double?, aneWatts: Double?, dramWatts: Double?
    /// SMC PSTR.
    public var systemWatts: Double?
    public var battery: BatterySnapshot?
    public var adapterWatts: Double?, adapterName: String?, lowPowerMode: Bool

    public init(
        packageWatts: Double? = nil,
        cpuWatts: Double? = nil,
        gpuWatts: Double? = nil,
        aneWatts: Double? = nil,
        dramWatts: Double? = nil,
        systemWatts: Double? = nil,
        battery: BatterySnapshot? = nil,
        adapterWatts: Double? = nil,
        adapterName: String? = nil,
        lowPowerMode: Bool = false
    ) {
        self.packageWatts = packageWatts
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.dramWatts = dramWatts
        self.systemWatts = systemWatts
        self.battery = battery
        self.adapterWatts = adapterWatts
        self.adapterName = adapterName
        self.lowPowerMode = lowPowerMode
    }
}
