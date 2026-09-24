import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

struct ThermalStateTests {
    @Test func mapping() {
        #expect(ThermalStateSensor.pressure(.nominal) == .nominal)
        #expect(ThermalStateSensor.pressure(.fair) == .fair)
        #expect(ThermalStateSensor.pressure(.serious) == .serious)
        #expect(ThermalStateSensor.pressure(.critical) == .critical)
    }

    /// Always safe to run (public API, no load): the sensor agrees with ProcessInfo right now.
    @Test func liveMatchesProcessInfo() throws {
        let s = ThermalStateSensor()
        try s.prepare()
        let (r, ns) = try s.sample(SampleContext())
        #expect(r == ThermalStateSensor.pressure(ProcessInfo.processInfo.thermalState))
        #expect(ns > 0)
    }
}
