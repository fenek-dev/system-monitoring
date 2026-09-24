import AppKit
import MonitorModel
import SwiftUI
import UniformTypeIdentifiers
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

    @Test func popoverMemoryMetricIsByteValue() {
        // Guards against `map(Double.init)`, which on UInt64? resolves to Double(bitPattern:).
        var a = AppSample(identity: AppIdentity(key: AppKey(kind: .app, id: "M"), displayName: "M"))
        a.memory = 4_294_967_296
        #expect(TTPopoverRow.metricValue(a, .memory) == 4_294_967_296)
    }

    @Test func popoverRowTapLogic() {
        var t = RowTapTracker()
        // Single click toggles immediately.
        var expanded = t.singleTap(expanded: false, at: 10, interval: 0.5)
        #expect(expanded)
        // Later single click (outside the interval) toggles back.
        expanded = t.singleTap(expanded: expanded, at: 12, interval: 0.5)
        #expect(!expanded)

        // Double-click where the count-1 recognizer fires on both clicks: net unchanged.
        var d = RowTapTracker()
        var s = false
        s = d.singleTap(expanded: s, at: 20, interval: 0.5)
        s = d.singleTap(expanded: s, at: 20.2, interval: 0.5)
        var opened = 0
        s = d.doubleTap(current: s) { opened += 1 }
        #expect(s == false && opened == 1)

        // Double-click where it fires only once: still restored to the pre-click state.
        var e = RowTapTracker()
        var x = true
        x = e.singleTap(expanded: x, at: 30, interval: 0.5)
        #expect(!x)
        x = e.doubleTap(current: x) { opened += 1 }
        #expect(x && opened == 2)
        // After a double-click, the next single click starts a new sequence.
        x = e.singleTap(expanded: x, at: 30.3, interval: 0.5)
        #expect(!x)
        let restored = e.doubleTap(current: x) { opened += 1 }
        #expect(restored && opened == 3)
    }

    @Test func sidebarValues() {
        #expect(!TTSidebarItem.hasValue(.overview) && !TTSidebarItem.hasValue(.processes) && !TTSidebarItem.hasValue(.history))
        #expect(TTSidebarItem.hasValue(.cpu) && TTSidebarItem.hasValue(.disk))
    }

    @MainActor @Test func showsCollectingDefaultsFromUnavailableReason() {
        #expect(TTMetricTile(category: .gpu, value: nil, unit: "%", detail: nil, points: [], unavailableReason: nil).showsCollecting)
        #expect(!TTMetricTile(category: .gpu, value: nil, unit: "%", detail: nil, points: [], unavailableReason: "n/a")
            .showsCollecting)
        #expect(TTMetricTile(category: .gpu, value: nil, unit: "%", detail: nil, points: [], unavailableReason: "n/a",
                             yDomain: nil, showsCollecting: true).showsCollecting)
        #expect(TTTimelineRow(label: "GPU", value: nil, points: [], color: .blue, yDomain: 0...1).showsCollecting)
        #expect(!TTTimelineRow(label: "GPU", icon: nil, value: nil, unavailableReason: "n/a", points: [], color: .blue,
                               yDomain: 0...1).showsCollecting)
    }

    @Test func textRenderingConfigureIsIdempotentAndNotPersisted() {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleFontSmoothing"] as? Int
        TTTextRendering.configure()
        TTTextRendering.configure()
        let arg = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        #expect(arg["AppleFontSmoothing"] as? Int == 0)
        #expect(UserDefaults.standard.integer(forKey: "AppleFontSmoothing") == 0)
        // Nothing written to the persistent global (or app) domain.
        #expect(UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleFontSmoothing"] as? Int == global)
        if let id = Bundle.main.bundleIdentifier {
            #expect(UserDefaults.standard.persistentDomain(forName: id)?["AppleFontSmoothing"] == nil)
        }
    }

    @MainActor @Test func appIconRuling() {
        #expect(AppIconCache.hasCustomIcon(bundlePath: "/System/Applications/Calculator.app"))
        #expect(!AppIconCache.hasCustomIcon(bundlePath: "/bin/ls"))
        #expect(!AppIconCache.hasCustomIcon(bundlePath: "/nonexistent/Telltale.app"))
        #expect(AppIconCache.icon(forPath: "/System/Applications/Calculator.app") != nil)
        #expect(AppIconCache.icon(forPath: "/bin/ls") == nil)
        #expect(AppIconCache.isGeneric(NSWorkspace.shared.icon(for: .unixExecutable)))
        #expect(AppIconCache.isGeneric(NSWorkspace.shared.icon(for: .application)))
        let blank = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            NSColor.white.setFill()
            r.fill()
            return true
        }
        #expect(AppIconCache.isGeneric(blank))
        // White-heavy real icon: white squircle with a colored glyph (~85 % white) is kept.
        let whiteHeavy = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            NSColor.white.setFill()
            r.fill()
            NSColor.systemBlue.setFill()
            NSRect(x: 5, y: 5, width: 6, height: 6).fill()
            return true
        }
        #expect(!AppIconCache.isGeneric(whiteHeavy))
    }

    @Test func chartSummary() {
        let s = ChartSeries(id: "u", label: "User", color: .blue,
                            points: [SeriesPoint(value: 0.1), SeriesPoint(value: 0.22), SeriesPoint(value: nil)])
        #expect(ChartAccessibility.summary([s], format: { TTFormat.percent($0) }) == "Chart, 3 samples: User latest 22%")
    }
}
