import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("Network snapshots")
@MainActor
struct NetworkSnapshotTests {
    @Test(arguments: [MockScenario.calm, .sensorsUnavailable, .collecting, .restricted])
    func network(_ scenario: MockScenario) {
        assertScreen("network", scenario: scenario)
    }

    /// "Today" comes from the store asynchronously; a synchronous render shows it only when injected.
    @Test func withTodayTotals() {
        let view = NetworkPage(today: (rx: 8_400_000_000, tx: 1_100_000_000))
            .frame(width: ScreenSize.pageContent.width, height: ScreenSize.pageContent.height)
            .screenEnvironment(.calm, page: .network)
        assertSnapshot(view, size: ScreenSize.pageContent, named: "network-today-calm")
    }

    @Test func todayTotalsFromStoreSinceMidnight() async throws {
        let history = MockDataProvider(scenario: .calm).history()
        let end = MockDataProvider.referenceDate
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let rx = try await history.total(.netRx, in: DateInterval(start: cal.startOfDay(for: end), end: end))
        #expect((rx ?? 0) > 0)
        let items = NetworkStatStrip.items(ScreenFixture.live(.calm), units: UnitPreferences(), today: (8.4e9, 1.1e9))
        #expect(items[2].value == "↓ 8.4 GB · ↑ 1.1 GB")
    }

    @Test func subtitleAndInterfaceDetailHaveNoSSID() {
        let live = ScreenFixture.live(.calm)
        #expect(NetworkPageContent.subtitle(live.network) == "Wi-Fi 6E · 5 GHz · 1,201 Mbps link")
        let primary = live.network.interfaces.first(where: \.isPrimary)!
        #expect(NetworkInterfacesCard.detail(primary, wifi: live.network.wifi) == "5 GHz · channel 149 · −52 dBm · 1,201 Mbps")
        let eth = InterfaceSnapshot(bsdName: "en7", displayName: "Ethernet", kind: .ethernet, isUp: true, isPrimary: true,
                                    linkRateBps: 1e9)
        #expect(NetworkPageContent.subtitle(NetworkSnapshot(interfaces: [eth])) == "Ethernet · 1,000 Mbps link")
        #expect(NetworkPageContent.bandText(2.4) == "2.4 GHz")
    }

    @Test func statStripBindings() {
        let items = NetworkStatStrip.items(ScreenFixture.live(.calm), units: UnitPreferences(), today: (nil, nil))
        #expect(items.map(\.label) == ["Download", "Upload", "Today", "Latency", "Packet loss"])
        #expect(items[0].detail == "Wi-Fi · en0")
        #expect(items[2].value == nil)
        #expect(items[3].value == "18 ms")
        #expect(items[3].detail == "to 192.168.1.1")
        #expect(items[4].value == "0.0%")
    }

    @Test func appsSortedByTotalAndSessionIsBothDirections() {
        let live = ScreenFixture.live(.calm)
        let rows = NetworkAppsCard.rows(live)
        #expect(!rows.isEmpty)
        #expect(zip(rows, rows.dropFirst()).allSatisfy {
            (NetworkAppsCard.total($0) ?? 0) >= (NetworkAppsCard.total($1) ?? 0)
        })
        if let a = rows.first, let rx = a.netRxSession, let tx = a.netTxSession {
            #expect(NetworkAppsCard.session(a) == rx + tx)
        }
    }

    @Test func throughputScaleOnlyGrowsWithinARange() {
        var c = NetworkThroughputCard.Ceilings()
        c = c.merged(range: .live, up: 40e6, down: 4e6)
        c = c.merged(range: .live, up: 20e6, down: 2e6)
        #expect(c.up == 40e6 && c.down == 4e6)
        c = c.merged(range: .hour, up: 20e6, down: 2e6)
        #expect(c.up == 20e6 && c.down == 2e6)
    }
}
