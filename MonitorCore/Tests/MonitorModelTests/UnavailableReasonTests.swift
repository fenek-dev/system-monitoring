import Foundation
import Testing
@testable import MonitorModel

@Suite struct UnavailableReasonTests {
    private let restricted = ProcessSample(id: ProcessID(pid: 88), name: "mds", provenance: .restricted)

    @Test func restrictedRowNamesCoalitionLeader() {
        var p = restricted
        p.coalitionLeaderName = "launchd"
        #expect(unavailableReason(.cpu, p, health: [:]) == "Owned by another user; counted in the launchd coalition row")
    }

    @Test func restrictedRowWithoutLeaderUsesGenericWording() {
        #expect(unavailableReason(.energy, restricted, health: [:]) == "Owned by another user; counted in its coalition row")
    }

    @Test(arguments: [AppMetric.cpu, .diskRead, .diskWrite, .energy])
    func restrictedRowReportsUnavailableCoalitions(_ metric: AppMetric) {
        let health: [SensorID: SensorStatus] = [.coalitions: .unavailable("coalition struct layout changed")]
        #expect(unavailableReason(metric, restricted, health: health) == "coalition struct layout changed")
    }

    @Test func restrictedMemoryReportsUnavailableRootMemory() {
        let health: [SensorID: SensorStatus] = [.rootMemory: .disabled("Disabled after a crash")]
        #expect(unavailableReason(.memory, restricted, health: health) == "Disabled after a crash")
        #expect(unavailableReason(.memory, restricted, health: [:]) == "Appears when the process table is open")
    }

    @Test func valuePresentHasNoReason() {
        var p = restricted
        p.cpuPercent = 3
        #expect(unavailableReason(.cpu, p, health: [.coalitions: .unavailable("x")]) == nil)
    }

    @Test func systemMetricNeedsAllSourcesDown() {
        #expect(unavailableReason(.gpuUsage, health: [.soc: .unavailable("no IOReport")]) == nil)
        #expect(unavailableReason(.gpuUsage, health: [.soc: .unavailable("no IOReport"), .gpuClients: .unavailable("no AGX")])
            == "no IOReport")
    }

    @Test func leaderNameDecodesWhenMissing() throws {
        let data = try JSONEncoder().encode(restricted)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "coalitionLeaderName")
        let decoded = try JSONDecoder().decode(ProcessSample.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.coalitionLeaderName == nil)
        #expect(decoded == restricted)
    }

    @Test func cadenceInitDefaultsToNeverInBackground() {
        #expect(SensorCadence(interactive: .seconds(2)).background == nil)
        #expect(SensorCadence.everyTick.background == .zero)
    }
}
