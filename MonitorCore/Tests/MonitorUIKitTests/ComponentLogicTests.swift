import MonitorModel
import SwiftUI
import Testing
@testable import MonitorUIKit

@Suite struct ComponentLogicTests {
    @Test func metricValuePresentation() {
        let na = MetricValue.presentation(nil, unavailableReason: "Requires root", estimated: false)
        #expect(na == .init(text: "—", unavailable: true, tooltip: "Requires root", accessibilityLabel: "Unavailable, Requires root"))
        let dash = MetricValue.presentation("—", unavailableReason: nil, estimated: false)
        #expect(dash.unavailable && dash.tooltip == nil && dash.accessibilityLabel == "Unavailable")
        let est = MetricValue.presentation("7.15 W", unavailableReason: nil, estimated: true)
        #expect(est == .init(text: "7.15 W", unavailable: false, tooltip: "Estimated", accessibilityLabel: "7.15 W, estimated"))
        let plain = MetricValue.presentation("34%", unavailableReason: "ignored", estimated: false)
        #expect(plain.tooltip == nil && !plain.unavailable)
    }

    @Test func unitJoin() {
        #expect(TTUnit.join("29", "%") == "29%")
        #expect(TTUnit.join("63", "°C") == "63°C")
        #expect(TTUnit.join("15.2", "GB") == "15.2 GB")
        #expect(TTUnit.join("15.2", " GB") == "15.2 GB")
        #expect(TTUnit.join("—", "W") == nil)
        #expect(TTUnit.join(nil, "W") == nil)
        #expect(TTUnit.join("3,104", nil) == "3,104")
    }

    @Test func segmentBarWidths() {
        // Power split: 4 segments + remainder, 2-pt gaps.
        let w = TTSegmentBar.widths([0.5, 0.25], remainder: true, width: 104, gap: 2)
        // 3 visible → 100 available: 50, 25, 25.
        #expect(w == [50, 25, 25])
        let noRest = TTSegmentBar.widths([0.5, 0, 0.25], remainder: false, width: 102, gap: 2)
        #expect(noRest == [50, 0, 25])
        let over = TTSegmentBar.widths([1, 1], remainder: true, width: 102, gap: 2)
        #expect(over == [50, 50, 0])
    }

    @Test func progressFillColor() {
        let t: [(Double, AlertLevel)] = [(0.6, .elevated), (0.8, .critical)]
        #expect(TTProgressBar.fillColor(value: 0.5, tint: TTColor.mem, thresholds: t) == TTColor.mem)
        #expect(TTProgressBar.fillColor(value: 0.7, tint: TTColor.mem, thresholds: t) == TTColor.statusElevated)
        #expect(TTProgressBar.fillColor(value: 0.9, tint: TTColor.mem, thresholds: t) == TTColor.statusCritical)
        #expect(TTProgressBar.fillColor(value: nil, tint: TTColor.mem, thresholds: t) == TTColor.mem)
    }

    @Test func appTileLetterAndRadius() {
        #expect(TTAppTile.letter("com.docker.backend") == "C")
        #expect(TTAppTile.letter("_windowserver") == "W")
        #expect(TTAppTile.letter("1Password") == "1")
        #expect(TTAppTile.letter("··") == "?")
        #expect([16, 20, 26, 44].map { TTAppTile.radius(CGFloat($0)) } == [4, 5, 7, 10])
    }

    @Test(.enUS) func popoverExpansionLines() {
        func app(_ n: String, cpu: Double? = nil, rx: Double? = nil, tx: Double? = nil, w: Double? = nil) -> AppSample {
            AppSample(identity: AppIdentity(key: AppKey(kind: .app, id: n), displayName: n), cpuPercent: cpu,
                      netRxBps: rx, netTxBps: tx, energyWatts: w)
        }
        let apps = [app("A", cpu: 5, rx: 1_000_000, w: 0.004), app("B", cpu: 212.4, tx: 2_000_000, w: 7.15),
                    app("C", cpu: 0), app("D", cpu: 18.7, rx: 100_000, tx: 50_000, w: 12.4), app("E", cpu: 9)]
        let u = UnitPreferences()
        #expect(TTPopoverRow.lines(apps, .cpu, units: u).map(\.name) == ["B", "D", "E"])
        #expect(TTPopoverRow.lines(apps, .cpu, units: u).map(\.value) == ["212.4%", "18.7%", "9.0%"])
        #expect(TTPopoverRow.lines(apps, .network, units: u).map(\.value) == ["2.0 MB/s", "1.0 MB/s", "150 KB/s"])
        #expect(TTPopoverRow.lines(apps, .thermals, units: u).map(\.value) == ["12.4 W", "7.15 W", "<0.01 W"])
        #expect(TTPopoverRow.lines([app("Z", cpu: 0)], .cpu, units: u).isEmpty)
        #expect(TTPopoverRow.page(.power) == .power)
    }

    @Test func sidebarValues() {
        #expect(!TTSidebarItem.hasValue(.overview) && !TTSidebarItem.hasValue(.processes) && !TTSidebarItem.hasValue(.history))
        #expect(TTSidebarItem.hasValue(.cpu) && TTSidebarItem.hasValue(.disk))
    }

    @Test func chartSummary() {
        let s = ChartSeries(id: "u", label: "User", color: .blue,
                            points: [SeriesPoint(value: 0.1), SeriesPoint(value: 0.22), SeriesPoint(value: nil)])
        #expect(ChartAccessibility.summary([s], format: { TTFormat.percent($0) }) == "Chart, 3 samples: User latest 22%")
    }
}
