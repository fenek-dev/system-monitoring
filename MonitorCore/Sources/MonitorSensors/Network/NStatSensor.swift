import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class NStatSensor: Sensor {
    public typealias Reading = NetworkFlowsReading
    public let id: SensorID = .networkFlows
    public let cadence: SensorCadence = SensorCadence(interactive: .zero, background: .seconds(10))

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: NetworkFlowsReading, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
