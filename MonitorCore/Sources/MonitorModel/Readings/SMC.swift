import Foundation

public struct RawFan: Sendable, Codable, Hashable {
    public var index: Int
    public var rpm, minRPM, maxRPM: Double
    public var name: String?

    public init(index: Int = 0, rpm: Double = 0, minRPM: Double = 0, maxRPM: Double = 0, name: String? = nil) {
        self.index = index
        self.rpm = rpm
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.name = name
    }
}

public struct SMCReading: Sendable, Codable {
    public var fans: [RawFan]
    /// Catalog-mapped T-keys (groups for background + alerts);
    /// + all cached T-keys when demand ∋ .rawTemperatures.
    public var temperatures: [RawTemperature]
    /// PSTR.
    public var systemWatts: Double?
    /// PDTR.
    public var adapterWatts: Double?

    public init(
        fans: [RawFan] = [],
        temperatures: [RawTemperature] = [],
        systemWatts: Double? = nil,
        adapterWatts: Double? = nil
    ) {
        self.fans = fans
        self.temperatures = temperatures
        self.systemWatts = systemWatts
        self.adapterWatts = adapterWatts
    }
}
