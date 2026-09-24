import Foundation

public struct BatterySnapshot: Sendable, Codable, Equatable {
    public var percent: Double?, isCharging: Bool, onAC: Bool, timeRemaining: Duration?
    public var healthFraction: Double?, cycleCount: Int?, condition: String?
    public var maxCapacityWh: Double?, designCapacityWh: Double?, currentCapacityWh: Double?
    public var temperatureC: Double?, drainWatts: Double?

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
        drainWatts: Double? = nil
    ) {
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
