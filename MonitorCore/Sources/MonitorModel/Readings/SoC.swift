import Foundation

public enum ClusterKind: String, Sendable, Codable { case performance, efficiency }

public struct ClusterResidency: Sendable, Codable, Hashable {
    /// "ECPU", "PCPU", "PCPU1".
    public var name: String
    public var kind: ClusterKind
    /// 1 − (IDLE|OFF|DOWN residency).
    public var activeFraction: Double
    /// nil unless PStateCatalog knows this chip.
    public var frequencyMHz: Double?, maxFrequencyMHz: Double?
    /// EACC_CPU / PACC*_CPU.
    public var watts: Double?

    public init(
        name: String = "",
        kind: ClusterKind = .performance,
        activeFraction: Double = 0,
        frequencyMHz: Double? = nil,
        maxFrequencyMHz: Double? = nil,
        watts: Double? = nil
    ) {
        self.name = name
        self.kind = kind
        self.activeFraction = activeFraction
        self.frequencyMHz = frequencyMHz
        self.maxFrequencyMHz = maxFrequencyMHz
        self.watts = watts
    }
}

public struct MediaEngineReading: Sendable, Codable, Hashable {
    public var name: String
    public var activeFraction: Double

    public init(name: String = "", activeFraction: Double = 0) {
        self.name = name
        self.activeFraction = activeFraction
    }
}

/// IOReport, delta over `interval`.
public struct SoCPowerReading: Sendable, Codable {
    public var interval: Duration
    public var cpuWatts, gpuWatts, aneWatts, dramWatts: Double?
    public var clusters: [ClusterResidency]
    /// MHz unresolved on M1 Max.
    public var gpuActiveFraction: Double?, gpuFrequencyMHz: Double?, gpuMaxFrequencyMHz: Double?
    /// Empty unless exposed (ruling).
    public var mediaEngines: [MediaEngineReading]

    public init(
        interval: Duration = .zero,
        cpuWatts: Double? = nil,
        gpuWatts: Double? = nil,
        aneWatts: Double? = nil,
        dramWatts: Double? = nil,
        clusters: [ClusterResidency] = [],
        gpuActiveFraction: Double? = nil,
        gpuFrequencyMHz: Double? = nil,
        gpuMaxFrequencyMHz: Double? = nil,
        mediaEngines: [MediaEngineReading] = []
    ) {
        self.interval = interval
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.dramWatts = dramWatts
        self.clusters = clusters
        self.gpuActiveFraction = gpuActiveFraction
        self.gpuFrequencyMHz = gpuFrequencyMHz
        self.gpuMaxFrequencyMHz = gpuMaxFrequencyMHz
        self.mediaEngines = mediaEngines
    }
}
