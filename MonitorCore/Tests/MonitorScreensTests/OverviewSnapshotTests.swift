import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("Overview snapshots")
@MainActor
struct OverviewSnapshotTests {
    @Test(arguments: [MockScenario.calm, .sensorsUnavailable, .collecting, .restricted, .paused, .deviceUnknown])
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
        #expect(W5a.freeBytes(v) == 382_000_000_000)
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

    /// Design match: the sidebar footer shows the short model name (DESIGN §3.0 "MacBook Pro 14″").
    @Test(arguments: [
        ("MacBook Pro (14-inch, 2021)", "MacBook Pro 14″"),
        ("MacBook Pro (16-inch, Nov 2023)", "MacBook Pro 16″"),
        ("MacBook Pro (13-inch, M2, 2022)", "MacBook Pro 13″"),
        ("MacBook Pro (14-inch)", "MacBook Pro 14″"),
        ("MacBook Air (13-inch, M3, 2024)", "MacBook Air 13″"),
        ("MacBook Air (15-inch, M2, 2023)", "MacBook Air 15″"),
        ("MacBook Air (M1, 2020)", "MacBook Air"),
        ("Mac mini (2023)", "Mac mini"),
        ("Mac Studio (2025)", "Mac Studio"),
        ("iMac (24-inch, 2023)", "iMac 24″"),
        ("MacBook Pro 14″", "MacBook Pro 14″"),
        ("Virtual Machine", "Virtual Machine"),
    ])
    func modelShortName(_ raw: String, _ expected: String) {
        #expect(ShellFormat.modelShortName(raw) == expected)
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
    }

    /// Non-Live range: titles follow the range, the store end is the display-bucket end (no per-tick dependency),
    /// and the page renders with the stored-range path (charts "Collecting…" until the async store read lands).
    @Test func hourRange() {
        let t = Date(timeIntervalSince1970: 1_000_007)
        #expect(RangeSeriesReaderBucket.end(t, range: .hour) == Date(timeIntervalSince1970: 1_000_020))   // 15-s buckets
        #expect(RangeSeriesReaderBucket.end(t, range: .day) == Date(timeIntervalSince1970: 1_000_200))    // 5-min
        #expect(HistoryRange.hour.lastTitle == "Last hour")
        // Fix4: after a range switch the old range's bucket end is never used.
        typealias Reader = RangeSeriesReader<EmptyView>
        let old = Reader.LoadKey(range: .day, bucketEnd: Date(timeIntervalSince1970: 1_000_200))
        #expect(Reader.storeEnd(clock: old, range: .hour, fallback: t) == Date(timeIntervalSince1970: 1_000_020))
        #expect(Reader.storeEnd(clock: old, range: .day, fallback: t) == Date(timeIntervalSince1970: 1_000_200))
        let ctx = ScreenFixture.context(.calm, page: .overview)
        ctx.navigation.range = .hour
        let view = DashboardRoot()
            .frame(width: ScreenSize.dashboard.width, height: ScreenSize.dashboard.height)
            .telltaleEnvironment(ctx)
        assertSnapshot(view, size: ScreenSize.dashboard, named: "overview-hour-calm")
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
