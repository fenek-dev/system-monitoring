import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("Overview snapshots", .serialized)
@MainActor
struct OverviewSnapshotTests {
    @Test(arguments: [MockScenario.calm, .sensorsUnavailable, .collecting, .restricted, .paused])
    func overview(_ scenario: MockScenario) {
        assertScreen("overview", scenario: scenario)
    }

    @Test func splitUnitRules() {
        #expect(splitUnit("15.1 GB") == ("15.1", "GB"))
        #expect(splitUnit("34%") == ("34", "%"))
        #expect(splitUnit("62°C") == ("62", "°C"))
        #expect(splitUnit("—") == (nil, nil))
    }

    @Test func diskUsedPhraseSharesUnit() {
        // CP2 ruling: free = available capacity, not "important usage" (which includes purgeable).
        let v = VolumeInfo(id: "/", name: "Macintosh HD", totalBytes: 994_000_000_000,
                           availableBytes: 382_000_000_000, availableImportantBytes: 450_000_000_000)
        #expect(OverviewDiskCard.usedPhrase(v) == "612 of 994 GB used")
        #expect(OverviewDiskCard.free(v) == 382_000_000_000)
    }

    /// Regression (review T2): rows are sorted by CPU *before* the "as many as fit" prefix, whatever order
    /// `LiveModel.apps` arrives in.
    @Test func topProcessesSortedBeforePrefix() {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        var f = provider.frame(at: 60)
        f.apps.reverse()                                  // worst case: ascending CPU order
        live.apply(f)
        live.isPresenting = true
        let rows = OverviewTopProcessesCard.rows(live)
        let best = f.apps.filter { $0.identity.key != .other }.max { ($0.cpuPercent ?? -1) < ($1.cpuPercent ?? -1) }
        #expect(rows.first?.identity.key == best?.identity.key)
        #expect(Array(rows.prefix(4)).map(\.identity.key) == Array(rows.sorted {
            ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1)
        }.prefix(4)).map(\.identity.key))
    }

    /// CP2: package watts fall back to the component sum; the popover Power row falls back to SMC system power.
    @Test func powerFallbacks() {
        var p = PowerSnapshot()
        p.cpuWatts = 3
        p.gpuWatts = 2
        #expect(W5a.packageWatts(p) == 5)
        p.cpuWatts = nil
        p.gpuWatts = nil
        #expect(W5a.packageWatts(p) == nil)
        #expect(W5a.loadAverage([27.5, 26.84, 25.1]) == "27.5 · 26.8 · 25.1")
        #expect(W5a.loadAverage([3.21, 2.88, 2.54]) == "3.21 · 2.88 · 2.54")
    }

    @Test func tileSubtitles() {
        let live = ScreenFixture.live(.calm)
        let tiles = OverviewTiles.tiles(RangeSeries(range: .live, end: .now, points: [:]), live: live,
                                        units: UnitPreferences())
        #expect(tiles[0].detail == "P 4.12 GHz · E 2.59 GHz")
        #expect(tiles[2].detail == "of 24 GB · pressure normal")
        #expect(tiles[3].detail?.hasSuffix("· Wi-Fi") == true)
        #expect(tiles[4].detail?.hasPrefix("SoC avg · fans ") == true)
    }
}
