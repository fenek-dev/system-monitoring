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
    /// ICR-6: true when the temperature catalog has an entry for this `hw.model` (groups verified);
    /// false → generic families (`ThermalSnapshot.approximateMapping`). Decoded with `decodeIfPresent` (old fixtures → false).
    public var catalogMatched: Bool

    public init(
        fans: [RawFan] = [],
        temperatures: [RawTemperature] = [],
        systemWatts: Double? = nil,
        adapterWatts: Double? = nil,
        catalogMatched: Bool = false
    ) {
        self.fans = fans
        self.temperatures = temperatures
        self.systemWatts = systemWatts
        self.adapterWatts = adapterWatts
        self.catalogMatched = catalogMatched
    }

    private enum CodingKeys: String, CodingKey { case fans, temperatures, systemWatts, adapterWatts, catalogMatched }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fans = try c.decode([RawFan].self, forKey: .fans)
        temperatures = try c.decode([RawTemperature].self, forKey: .temperatures)
        systemWatts = try c.decodeIfPresent(Double.self, forKey: .systemWatts)
        adapterWatts = try c.decodeIfPresent(Double.self, forKey: .adapterWatts)
        catalogMatched = try c.decodeIfPresent(Bool.self, forKey: .catalogMatched) ?? false
    }
}
