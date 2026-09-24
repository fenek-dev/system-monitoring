import Foundation
import MonitorModel

/// System thermal pressure (`ProcessInfo.thermalState`, public; < 1 µs).
public final class ThermalStateSensor: Sensor {
    public typealias Reading = ThermalPressure
    public let id: SensorID = .thermalState
    public let cadence: SensorCadence = .everyTick

    public init() {}

    public func prepare() throws(SensorError) {}

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: ThermalPressure, capturedNs: UInt64) {
        (Self.pressure(ProcessInfo.processInfo.thermalState), w6bUptimeNs())
    }

    public func invalidate() {}

    static func pressure(_ s: ProcessInfo.ThermalState) -> ThermalPressure {
        switch s {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}
