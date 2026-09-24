import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class DiskIOSensor: Sensor {
    public typealias Reading = DiskIOReading
    public let id: SensorID = .diskIO
    public let cadence: SensorCadence = .everyTick

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: DiskIOReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
