import AppKit
import MonitorModel
import os
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

    @Test(.enUS) func popoverAppMetricFormats() {
        let app = AppSample(identity: AppIdentity(key: AppKey(kind: .app, id: "N"), displayName: "N"),
                            netRxBps: 100_000, netTxBps: 50_000, diskWriteBps: 2_000_000)
        let u = UnitPreferences()
        #expect(TTPopoverRow.metricValue(app, .network) == 150_000)
        #expect(TTPopoverRow.metricValue(app, .disk) == 2_000_000)
        #expect(TTPopoverRow.metricValue(app, .cpu) == nil)
        #expect(TTPopoverRow.format(212.4, .cpu, units: u) == "212.4%")
        #expect(TTPopoverRow.format(150_000, .network, units: u) == "150 KB/s")
        #expect(TTPopoverRow.format(0.004, .thermals, units: u) == "<0.01 W")
        #expect(TTPopoverRow.page(.power) == .power)
    }

    @Test func popoverMemoryMetricIsByteValue() {
        // Guards against `map(Double.init)`, which on UInt64? resolves to Double(bitPattern:).
        var a = AppSample(identity: AppIdentity(key: AppKey(kind: .app, id: "M"), displayName: "M"))
        a.memory = 4_294_967_296
        #expect(TTPopoverRow.metricValue(a, .memory) == 4_294_967_296)
    }

    /// A single click on a popover row opens that category's dashboard page (no inline expansion).
    @MainActor @Test func popoverRowClickOpensPage() {
        let log = OSAllocatedUnfairLock<[String]>(initialState: [])
        let commands = AppCommands(openDashboard: { p in log.withLock { $0.append("open \(p?.rawValue ?? "nil")") } },
                                   inspectApp: { k in log.withLock { $0.append("inspect \(k.id)") } })
        TTPopoverRow.click(.memory, commands: commands)
        TTPopoverRow.click(.thermals, commands: commands)
        #expect(log.withLock { $0 } == ["open memory", "open thermals"])
    }

    /// "Show top apps" (keyboard/VoiceOver) asks for the flyout at once, with the row's frame.
    @MainActor @Test func popoverRowShowTopAppsAction() {
        let events = OSAllocatedUnfairLock<[PopoverRowHover]>(initialState: [])
        let frame = CGRect(x: 7, y: 60, width: 346, height: 44)
        TTPopoverRow.showTopApps(.gpu, frame: frame) { e in events.withLock { $0.append(e) } }
        #expect(events.withLock { $0 } == [PopoverRowHover(category: .gpu, phase: .show, frame: frame)])
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

    /// Overlay R6: the memory stats row drops the unit but keeps `memory(.headline)`'s divisor and digits.
    @Test(.enUS) func memoryNumberMatchesHeadlineWithoutUnit() {
        let b: UInt64 = 16_320_000_000
        #expect(TTFormat.memoryNumber(b) == "15.2")
        #expect(TTFormat.memory(b, style: .headline) == TTFormat.memoryNumber(b) + " GB")
        for v: UInt64 in [0, 900_000_000, 1_073_741_824, 2_199_023_255_552] {
            let headline = TTFormat.memory(v, style: .headline)
            #expect(TTFormat.memoryNumber(v) == String(headline.prefix { $0 != " " }))
        }
        #expect(TTFormat.memoryNumber(nil) == "—")
    }
}
