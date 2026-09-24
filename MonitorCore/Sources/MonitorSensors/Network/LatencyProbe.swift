import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class LatencyProbe: Sensor {
    public typealias Reading = LatencyReading
    public let id: SensorID = .latency
    public let cadence: SensorCadence = .every(.seconds(10), background: .seconds(10))

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: LatencyReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
