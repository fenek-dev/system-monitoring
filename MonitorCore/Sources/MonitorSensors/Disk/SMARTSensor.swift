import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class SMARTSensor: Sensor {
    public typealias Reading = SMARTInfo
    public let id: SensorID = .smart
    public let cadence: SensorCadence = .every(.seconds(300), requires: .smart)

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: SMARTInfo, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
