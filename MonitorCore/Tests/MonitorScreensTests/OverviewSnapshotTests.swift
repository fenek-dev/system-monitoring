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
        let v = VolumeInfo(id: "/", name: "Macintosh HD", totalBytes: 994_000_000_000,
                           availableBytes: 300_000_000_000, availableImportantBytes: 382_000_000_000)
        #expect(OverviewDiskCard.usedPhrase(v) == "612 of 994 GB used")
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
