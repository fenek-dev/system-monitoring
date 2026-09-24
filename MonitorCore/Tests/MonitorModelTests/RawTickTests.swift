import Foundation
import Testing
@testable import MonitorModel

@Suite struct RawTickTests {
    private func sampleTick() -> RawTick {
        var tick = RawTick(wallTime: Date(timeIntervalSince1970: 1_790_000_000), uptimeNs: 42, mode: .interactive,
                           demand: [.perCore, .processTable])
        tick.coalitions = .fresh(CoalitionsReading(coalitions: [CoalitionUsage(id: 7, cpuTimeNs: 100)]), capturedNs: 40)
        tick.thermalState = .cached(.fair, capturedNs: 30)
        tick.wifi = .failed(.permissionDenied("wifi"), last: nil, capturedNs: nil)
        tick.health = [.coalitions: .ok, .wifi: .unavailable("no Wi-Fi")]
        return tick
    }

    @Test func missingCoalitionsKeyDecodesAsNotRequested() throws {
        let data = try JSONEncoder().encode(sampleTick())
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["coalitions"] != nil)
        object.removeValue(forKey: "coalitions")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let tick = try JSONDecoder().decode(RawTick.self, from: stripped)
        guard case .notRequested = tick.coalitions else {
            Issue.record("expected .notRequested, got \(tick.coalitions)")
            return
        }
        #expect(tick.uptimeNs == 42)
        #expect(tick.mode == .interactive)
        #expect(tick.demand == [.perCore, .processTable])
        guard case .cached(.fair, capturedNs: 30) = tick.thermalState else {
            Issue.record("thermalState not preserved: \(tick.thermalState)")
            return
        }
        #expect(tick.health[.wifi] == .unavailable("no Wi-Fi"))
    }

    @Test func minimalFixtureDecodesEverySensorAsNotRequested() throws {
        let json = #"{"wallTime": 0, "uptimeNs": 5, "mode": "background"}"#
        let tick = try JSONDecoder().decode(RawTick.self, from: Data(json.utf8))
        #expect(tick.uptimeNs == 5)
        #expect(tick.demand == [])
        #expect(tick.health.isEmpty)
        #expect(tick.processes.value == nil)
        #expect(tick.device.capturedNs == nil)
        guard case .notRequested = tick.smc, case .notRequested = tick.sleepAssertions else {
            Issue.record("expected .notRequested")
            return
        }
    }

    @Test func roundTrips() throws {
        let tick = sampleTick()
        let decoded = try JSONDecoder().decode(RawTick.self, from: JSONEncoder().encode(tick))
        #expect(decoded.wallTime == tick.wallTime)
        #expect(decoded.coalitions.value?.coalitions == tick.coalitions.value?.coalitions)
        #expect(same(decoded.wifi, tick.wifi))
        #expect(decoded.health == tick.health)
    }
}
