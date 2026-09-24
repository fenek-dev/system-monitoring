import Foundation

public struct GPUSnapshot: Sendable, Codable, Equatable {
    public var usage: Double?, frequencyMHz: Double?, maxFrequencyMHz: Double?, watts: Double?
    public var allocatedMemory: UInt64?, coreCount: Int?, aneWatts: Double?, mediaEngines: [MediaEngineReading]

    public init(
        usage: Double? = nil,
        frequencyMHz: Double? = nil,
        maxFrequencyMHz: Double? = nil,
        watts: Double? = nil,
        allocatedMemory: UInt64? = nil,
        coreCount: Int? = nil,
        aneWatts: Double? = nil,
        mediaEngines: [MediaEngineReading] = []
    ) {
        self.usage = usage
        self.frequencyMHz = frequencyMHz
        self.maxFrequencyMHz = maxFrequencyMHz
        self.watts = watts
        self.allocatedMemory = allocatedMemory
        self.coreCount = coreCount
        self.aneWatts = aneWatts
        self.mediaEngines = mediaEngines
    }
}
