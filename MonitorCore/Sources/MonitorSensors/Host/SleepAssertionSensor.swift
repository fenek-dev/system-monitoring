import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class SleepAssertionSensor: Sensor {
    public typealias Reading = SleepAssertionsReading
    public let id: SensorID = .sleepAssertions
    public let cadence: SensorCadence = .every(.seconds(5), background: .seconds(60))

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: SleepAssertionsReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
