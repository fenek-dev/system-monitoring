import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine
@testable import MonitorRuntime

/// Settings "Re-enable sensors" ↔ crash canary: same suite, same keys (canary API contract).
@Suite(.serialized) struct CrashCanaryRuntimeTests {
    static func suite() -> String { "dev.telltale.tests.canary-\(UUID().uuidString)" }

    @Test func reenableClearsMarkersInTheGivenSuite() {
        let name = Self.suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let canary = TelltaleRuntime.canary(suite: name)
        canary.arm(.smc)                                          // what a crash inside prepare() leaves behind
        canary.arm(.soc)
        #expect(canary.isTripped(.smc) && canary.isTripped(.soc))
        #expect(!CrashCanary.standard.isTripped(.smc))            // the suite, not standard defaults

        TelltaleRuntime.reenableCrashedSensors(canarySuite: name)
        #expect(!canary.isTripped(.smc) && !canary.isTripped(.soc))
    }

    @Test func trippedMarkerDisablesTheSensorUntilReenabled() async {
        let name = Self.suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        TelltaleRuntime.canary(suite: name).arm(.smc)
        let factory = SensorFactory { _ in SensorSuite(smc: FixtureSensor(.smc, readings: [.success(SMCReading())])) }

        let crashed = SamplingEngine(factory: factory, canary: TelltaleRuntime.canary(suite: name))
        let f = await crashed.sampleOnce()
        #expect(f.sensorHealth[.smc]?.reason == "Disabled after a crash")
        await crashed.stop()

        TelltaleRuntime.reenableCrashedSensors(canarySuite: name)
        let fresh = SamplingEngine(factory: factory, canary: TelltaleRuntime.canary(suite: name))
        #expect(await fresh.sampleOnce().sensorHealth[.smc] == .ok)
        await fresh.stop()
    }
}
