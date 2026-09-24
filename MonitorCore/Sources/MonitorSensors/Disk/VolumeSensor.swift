import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class VolumeSensor: Sensor {
    public typealias Reading = VolumesReading
    public let id: SensorID = .volumes
    public let cadence: SensorCadence = .every(.seconds(10), background: .seconds(60))

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: VolumesReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
