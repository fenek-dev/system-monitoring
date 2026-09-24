import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class CoalitionSensor: Sensor {
    public typealias Reading = CoalitionsReading
    public let id: SensorID = .coalitions
    public let cadence: SensorCadence = .everyTick

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: CoalitionsReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
