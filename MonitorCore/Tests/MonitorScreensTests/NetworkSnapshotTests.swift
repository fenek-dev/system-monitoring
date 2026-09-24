import AppKit
import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// A persistent offscreen `NSHostingView` (the snapshot renderer builds a fresh host per call, which can't show
/// whether an existing hierarchy updates). Same deterministic environment as `SnapshotRenderer.prepared`.
@MainActor
final class LiveHost {
    private let host: NSHostingView<AnyView>
    private let window: NSWindow
    private let size: CGSize

    init<V: View>(_ view: V, size: CGSize) {
        self.size = size
        // Before any text is drawn in this process: font smoothing is read once (else later goldens shift).
        SnapshotRenderer.configureTextRendering()
        _ = NSApplication.shared
        host = NSHostingView(rootView: AnyView(SnapshotRenderer.prepared(view, size: size)))
        host.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
    }

    deinit { MainActor.assumeIsolated { window.close() } }

    func image() -> CGImage? {
        TTFormat.$locale.withValue(SnapshotRenderer.locale) { () -> CGImage? in
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            let rect = CGRect(origin: .zero, size: size)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            host.cacheDisplay(in: rect, to: rep)
            return rep.cgImage.flatMap { SnapshotImage.normalized($0) }
        }
    }
}

@Suite("Network snapshots")
@MainActor
struct NetworkSnapshotTests {
    @Test(arguments: [MockScenario.calm, .sensorsUnavailable, .collecting, .restricted])
    func network(_ scenario: MockScenario) {
        assertScreen("network", scenario: scenario)
    }

    /// U-M2: rows are Equatable on their `AppSample`, and cells capture `units`. Switching Settings → units to bits
    /// in a live host must redraw rows whose data did not change (`columnsVersion`): the updated host matches a
    /// fresh bits render and differs from the bytes render.
    @Test func switchingUnitsRerendersNetworkRows() throws {
        let size = CGSize(width: 1020, height: 320)
        let ctx = ScreenFixture.context(.calm, page: .network)
        let card = NetworkAppsCard().telltaleEnvironment(ctx)
        let host = LiveHost(card, size: size)
        let bytes = try #require(host.image())
        ctx.settings.units = UnitPreferences(networkRate: .bits)
        let switched = try #require(host.image())

        let fresh = ScreenFixture.context(.calm, page: .network)
        fresh.settings.units = UnitPreferences(networkRate: .bits)
        let bits = try #require(LiveHost(NetworkAppsCard().telltaleEnvironment(fresh), size: size).image())
        #expect(SnapshotImage.compare(bytes, bits).fraction > 0.001)       // the units do change the cells
        #expect(SnapshotImage.compare(switched, bits).fraction < 0.0005)   // and the live rows followed
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
        let zone = try #require(TimeZone(identifier: "Europe/London"))
        let rx = try await history.total(.netRx, in: NetworkPageContent.todayInterval(end: end, timeZone: zone))
        #expect((rx ?? 0) > 0)
        let items = NetworkStatStrip.items(ScreenFixture.live(.calm), units: UnitPreferences(), today: (8.4e9, 1.1e9))
        #expect(items[2].value == "↓ 8.4 GB · ↑ 1.1 GB")
    }

    /// A9: "Today" starts at local midnight of the given zone, also across a DST change.
    @Test func todayIntervalNonUTCAndDST() throws {
        let ny = try #require(TimeZone(identifier: "America/New_York"))
        let iso = ISO8601DateFormatter()
        // 2026-09-24 03:30 UTC is 23:30 on the 23rd in New York → midnight 2026-09-23 04:00 UTC.
        let late = try #require(iso.date(from: "2026-09-24T03:30:00Z"))
        #expect(NetworkPageContent.todayInterval(end: late, timeZone: ny).start == iso.date(from: "2026-09-23T04:00:00Z"))
        // DST start 2026-03-08 (clocks jump 02:00 → 03:00 EST→EDT): midnight is still 05:00 UTC (EST), and the
        // interval to 12:00 EDT (16:00 UTC) is 11 h, not 12.
        let noon = try #require(iso.date(from: "2026-03-08T16:00:00Z"))
        let dst = NetworkPageContent.todayInterval(end: noon, timeZone: ny)
        #expect(dst.start == iso.date(from: "2026-03-08T05:00:00Z"))
        #expect(dst.duration == 11 * 3_600)
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

    @Test func appsSortedByTotalAndSessionIsBothDirections() throws {
        let live = ScreenFixture.live(.calm)
        let rows = NetworkAppsCard.rows(live)
        #expect(!rows.isEmpty)
        #expect(zip(rows, rows.dropFirst()).allSatisfy {
            (NetworkAppsCard.total($0) ?? 0) >= (NetworkAppsCard.total($1) ?? 0)
        })
        let a = try #require(rows.first)
        let rx = try #require(a.netRxSession)
        let tx = try #require(a.netTxSession)
        #expect(NetworkAppsCard.session(a) == rx + tx)
    }

    /// A5: with the per-app flow sensor unavailable the table lists the groups (cells "—" + reason), not nothing.
    @Test func flowsUnavailableKeepsRows() throws {
        var apps = ScreenFixture.live(.calm).apps
        for i in apps.indices {
            apps[i].netRxBps = nil
            apps[i].netTxBps = nil
            apps[i].netRxSession = nil
            apps[i].netTxSession = nil
        }
        #expect(NetworkAppsCard.rank(apps, flowsUnavailable: false).isEmpty)
        #expect(NetworkAppsCard.rank(apps, flowsUnavailable: true).count == apps.filter { $0.identity.key != .other }.count)
        #expect(NetworkAppsCard.flowsReason([.networkFlows: .unavailable("NetworkStatistics not available")])
            == "NetworkStatistics not available")
        #expect(NetworkAppsCard.flowsReason([:]) == nil)
    }

    /// B6: Live scales only grow; stored ranges use the window's own ceiling every time.
    @Test func throughputScaleOnlyGrowsInLive() {
        var c = NetworkThroughputCard.Ceilings()
        c = c.merged(range: .live, up: 40e6, down: 4e6)
        c = c.merged(range: .live, up: 20e6, down: 2e6)
        #expect(c.up == 40e6 && c.down == 4e6)
        c = c.merged(range: .hour, up: 20e6, down: 2e6)
        #expect(c.up == 20e6 && c.down == 2e6)
        c = c.merged(range: .hour, up: 10e6, down: 1e6)
        #expect(c.up == 10e6 && c.down == 1e6)
    }

    /// C6: in bits mode the scale is nice in Mbps.
    @Test func bitsScaleIsNiceInMbps() {
        var bits = UnitPreferences()
        bits.networkRate = .bits
        let t = Date(timeIntervalSince1970: 0)
        let pts = [SeriesPoint(time: t, value: 4_200_000), SeriesPoint(time: t.addingTimeInterval(1), value: 1_000)]
        let c = NetworkThroughputCard.ceiling(pts, units: bits)
        #expect(TTFormat.rateScale(c, units: bits) == "40 Mbps")
        #expect(NetworkStatStrip.fallbackRateReason(.collecting(since: t)) == "Collecting — rates need two samples")
    }
}
