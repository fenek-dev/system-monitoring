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

    @Test func chartSummary() {
        let s = ChartSeries(id: "u", label: "User", color: .blue,
                            points: [SeriesPoint(value: 0.1), SeriesPoint(value: 0.22), SeriesPoint(value: nil)])
        #expect(ChartAccessibility.summary([s], format: { TTFormat.percent($0) }) == "Chart, 3 samples: User latest 22%")
    }
}
