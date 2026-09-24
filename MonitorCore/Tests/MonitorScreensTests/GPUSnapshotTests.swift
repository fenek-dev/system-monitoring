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
        let items = GPUStatStrip.statItems(ScreenFixture.live(.calm))
        #expect(items.map(\.label) == ["Utilization", "Frequency", "GPU power", "GPU memory", "Cores"])
        #expect(items[1].detail == "of 1,578 MHz")
        #expect(items[3].detail == "allocated from unified memory")
        #expect(items[4].value == "16")
    }

    /// C1: media engine "idle" under 0.5 %; GPU time tooltip keyed on the GPU time itself.
    /// Ruling: one "Media engine" row; IOReport channels combined by max activeFraction.
    @Test func mediaEnginesCombineIntoOneRow() {
        let one = GPUMediaEnginesCard.combined([MediaEngineReading(name: "Video encoder/scaler", activeFraction: 0.22)])
        #expect(one == MediaEngineReading(name: "Media engine", activeFraction: 0.22))
        let many = GPUMediaEnginesCard.combined([MediaEngineReading(name: "A", activeFraction: 0.1),
                                                 MediaEngineReading(name: "B", activeFraction: 0.4)])
        #expect(many?.activeFraction == 0.4)
        #expect(GPUMediaEnginesCard.combined([]) == nil)
        #expect(ScreenFixture.live(.calm).gpu.mediaEngines.count == 1)   // mock follows the ruling
    }

    @Test func mediaValueAndGPUTimeReason() throws {
        #expect(GPUMediaEnginesCard.valueText(0.004) == "idle")
        #expect(GPUMediaEnginesCard.valueText(0.22) == "22%")
        var app = try #require(ScreenFixture.live(.calm).apps.first)
        app.gpuPercent = 3
        app.gpuTimeNs = nil
        #expect(GPUClientsCard.gpuTimeReason(app, health: [:]) != nil)
        app.gpuTimeNs = 1_000_000_000
        app.gpuPercent = nil
        #expect(GPUClientsCard.gpuTimeReason(app, health: [:]) == nil)
    }

    @Test func clientsAreGPUActiveAppsByShare() {
        let rows = GPUClientsCard.rows(ScreenFixture.live(.calm))
        #expect(!rows.isEmpty)
        #expect(zip(rows, rows.dropFirst()).allSatisfy { ($0.gpuPercent ?? 0) >= ($1.gpuPercent ?? 0) })
    }
}
