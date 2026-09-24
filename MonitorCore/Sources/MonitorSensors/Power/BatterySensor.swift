import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class BatterySensor: Sensor {
    public typealias Reading = BatteryReading
    public let id: SensorID = .battery
    public let cadence: SensorCadence = .every(.seconds(5), background: .seconds(30))

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: BatteryReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
