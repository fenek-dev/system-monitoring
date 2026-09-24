import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class RootMemorySensor: Sensor {
    public typealias Reading = RootMemoryReading
    public let id: SensorID = .rootMemory
    public let cadence: SensorCadence = .every(.seconds(30), background: .seconds(30), requires: [.processTable, .memoryAlert])

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: RootMemoryReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
