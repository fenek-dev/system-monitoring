import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class HIDTemperatureSensor: Sensor {
    public typealias Reading = TemperatureReading
    public let id: SensorID = .temperatures
    public let cadence: SensorCadence = .every(.seconds(2), requires: .rawTemperatures)

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: TemperatureReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
