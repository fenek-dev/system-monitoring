import MonitorModel

// W0b stub (ARCHITECTURE §2, §5.4 cadence table). The owning W6 stream replaces this file.

public final class WiFiSensor: Sensor {
    public typealias Reading = WiFiInfo
    public let id: SensorID = .wifi
    public let cadence: SensorCadence = .every(.seconds(2), background: .seconds(30))

    public init() {}

    public func prepare() throws(SensorError) {
        throw .unavailable("not implemented")
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: WiFiInfo, capturedNs: UInt64) {
        throw .unavailable("not implemented")
    }

    public func invalidate() {}
}
