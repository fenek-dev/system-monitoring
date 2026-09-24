import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("CPU snapshots")
@MainActor
struct CPUSnapshotTests {
    @Test(arguments: [MockScenario.calm, .sensorsUnavailable, .collecting, .restricted])
    func cpu(_ scenario: MockScenario) {
        assertScreen("cpu", scenario: scenario)
    }

    /// Selected user-owned row → inline [Quit][Force Quit] (DESIGN §2.20), as the artboard shows.
    @Test func selectedRow() {
        let live = ScreenFixture.live(.calm)
        let second = CPUConsumersCard.rows(live)[1]
        let view = CPUPage(selection: second.id)
            .frame(width: ScreenSize.pageContent.width, height: ScreenSize.pageContent.height)
            .screenEnvironment(.calm, page: .cpu)
        assertSnapshot(view, size: ScreenSize.pageContent, named: "cpu-selected-calm")
    }

    @Test func statStripBindings() {
        let items = CPUStatStrip.items(ScreenFixture.live(.calm))
        #expect(items.map(\.label) == ["Total", "User", "System", "Idle", "Load average", "Threads"])
        #expect(items[0].detail == "of 12 cores")
        #expect(items[1].value?.contains(".") == true)            // breakdown: 1 decimal
        #expect(items[4].detail == "1 · 5 · 15 min")
        #expect(items[5].detail?.hasPrefix("in ") == true)
    }

    @Test func clusterFrequency() {
        var c = ClusterSnapshot(kind: .performance, coreCount: 8, usage: nil, activeResidency: nil, frequencyMHz: 4_120,
                                maxFrequencyMHz: 4_510, watts: nil)
        #expect(CPUClusterCard.frequency(c) == "4.12 GHz of 4.51 GHz")
        c.maxFrequencyMHz = nil
        #expect(CPUClusterCard.frequency(c) == "4.12 GHz")
        c.frequencyMHz = nil
        #expect(CPUClusterCard.frequency(c) == nil)                 // "—" when the catalog lacks the chip
    }
}
