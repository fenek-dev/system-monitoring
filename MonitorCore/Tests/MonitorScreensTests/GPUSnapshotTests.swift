import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("GPU snapshots")
@MainActor
struct GPUSnapshotTests {
    @Test(arguments: [MockScenario.calm, .sensorsUnavailable, .collecting, .restricted])
    func gpu(_ scenario: MockScenario) {
        assertScreen("gpu", scenario: scenario)
    }

    /// No media-engine residency → the card is removed and the ANE card fills the column (DESIGN §3.6.4).
    @Test func withoutMediaEngines() {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.gpu.mediaEngines = []
            live.apply(f)
        }
        live.isPresenting = true
        var ctx = ScreenFixture.context(.calm, page: .gpu)
        ctx.live = live
        let view = GPUPage()
            .frame(width: ScreenSize.pageContent.width, height: ScreenSize.pageContent.height)
            .telltaleEnvironment(ctx)
        assertSnapshot(view, size: ScreenSize.pageContent, named: "gpu-no-media-calm")
    }

    @Test func statStripBindings() {
        let items = GPUPageContent.statItems(ScreenFixture.live(.calm))
        #expect(items.map(\.label) == ["Utilization", "Frequency", "GPU power", "GPU memory", "Cores"])
        #expect(items[1].detail == "of 1,578 MHz")
        #expect(items[3].detail == "allocated from unified memory")
        #expect(items[4].value == "16")
    }

    @Test func clientsAreGPUActiveAppsByShare() {
        let rows = GPUClientsCard.rows(ScreenFixture.live(.calm))
        #expect(!rows.isEmpty)
        #expect(zip(rows, rows.dropFirst()).allSatisfy { ($0.gpuPercent ?? 0) >= ($1.gpuPercent ?? 0) })
    }
}
