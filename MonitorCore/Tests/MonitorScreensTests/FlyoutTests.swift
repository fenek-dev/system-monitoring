import CoreGraphics
import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// Popover hover flyout (DESIGN §2.22 "Flyout"): ranking + share maths, placement, hover intent, goldens.
@Suite("Flyout")
@MainActor
struct FlyoutTests {
    static func app(_ id: String, kind: AppKey.Kind = .app, cpu: Double? = nil, mem: UInt64? = nil,
                    rx: Double? = nil, tx: Double? = nil, watts: Double? = nil) -> AppSample {
        AppSample(identity: AppIdentity(key: AppKey(kind: kind, id: id), displayName: id), cpuPercent: cpu, memory: mem,
                  netRxBps: rx, netTxBps: tx, energyWatts: watts)
    }

    // MARK: FlyoutModel

    /// share = value / Σ over every app with a value on the metric (`.other` included in Σ, never listed);
    /// nil / zero / non-finite values are neither listed nor summed.
    @Test func shareIsValueOverSumOfAllApps() {
        let apps = [Self.app("A", cpu: 30), Self.app("B", cpu: 10), Self.app("C"), Self.app("D", cpu: 0),
                    Self.app("E", cpu: .nan), AppSample(identity: AppIdentity(key: .other, displayName: "Other"),
                                                        cpuPercent: 60)]
        let lines = FlyoutModel.lines(apps: apps, category: .cpu)
        #expect(lines.map(\.name) == ["A", "B"])
        #expect(lines.map(\.value) == [30, 10])
        #expect(lines.map(\.share) == [0.3, 0.1])
    }

    @Test func shareUsesTheCategoryMetric() {
        let apps = [Self.app("A", mem: 3_000_000_000, rx: 100, tx: 300, watts: 1),
                    Self.app("B", mem: 1_000_000_000, rx: 400, watts: 3)]
        #expect(FlyoutModel.lines(apps: apps, category: .memory).map(\.share) == [0.75, 0.25])
        #expect(FlyoutModel.lines(apps: apps, category: .memory).first?.value == 3_000_000_000)
        #expect(FlyoutModel.lines(apps: apps, category: .network).map(\.share) == [0.5, 0.5])   // ↓+↑
        #expect(FlyoutModel.lines(apps: apps, category: .thermals).map(\.name) == ["B", "A"])  // by power
        #expect(FlyoutModel.lines(apps: [], category: .cpu).isEmpty)
        #expect(FlyoutModel.lines(apps: [Self.app("Z", cpu: 0)], category: .cpu).isEmpty)
    }

    /// Top 10 by value, descending; equal values keep their input order (stable).
    @Test func topTenWithStableTies() {
        let values: [Double] = [5, 9, 5, 1, 9, 5, 7, 5, 2, 5, 3, 5]
        let apps = values.enumerated().map { Self.app("a\($0.offset)", cpu: $0.element) }
        let lines = FlyoutModel.lines(apps: apps, category: .cpu)
        #expect(lines.count == 10)
        #expect(lines.map(\.name) == ["a1", "a4", "a6", "a0", "a2", "a5", "a7", "a9", "a11", "a10"])
        #expect(FlyoutModel.lines(apps: apps, category: .cpu, limit: 3).map(\.name) == ["a1", "a4", "a6"])
        // Σ covers all 12 apps, not just the listed 10.
        #expect(lines.first?.share == 9 / values.reduce(0, +))
    }

    @Test func headerAndValueFormats() {
        let u = UnitPreferences()
        #expect(FlyoutModel.header(.cpu, total: "34%") == "Top CPU · 34% total")
        #expect(FlyoutModel.header(.cpu, total: nil) == "Top CPU")
        #expect(FlyoutModel.header(.thermals, total: "62°C") == "Top Thermals · 62°C")    // a temperature is no total
        TTFormat.$locale.withValue(Locale(identifier: "en_US")) {
            #expect(FlyoutModel.format(212.4, .cpu, units: u) == "212.4%")
            #expect(FlyoutModel.format(12.4, .thermals, units: u) == "12.4 W")
            #expect(FlyoutModel.format(2_000_000, .network, units: u) == "2.0 MB/s")
        }

        let live = ScreenFixture.live(.calm)
        #expect(FlyoutModel.total(.cpu, live: live, units: u) == TTFormat.percent(live.cpu.usage))
        #expect(FlyoutModel.total(.memory, live: live, units: u) == TTFormat.memory(live.memory.used, style: .headline))
    }

    /// Ranking runs once per `appsVersion` (and category), never per body evaluation.
    @Test func rankingCachedPerAppsVersion() {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        live.apply(provider.frame(at: 0))
        live.isPresenting = true
        let cache = FlyoutLinesCache()
        let first = cache.lines(live: live, category: .cpu)
        _ = cache.lines(live: live, category: .cpu)
        #expect(cache.computations == 1)
        #expect(first == FlyoutModel.lines(apps: live.apps, category: .cpu))
        _ = cache.lines(live: live, category: .memory)
        #expect(cache.computations == 2)
        live.apply(provider.frame(at: 1))
        _ = cache.lines(live: live, category: .memory)
        #expect(cache.computations == 3)
    }

    // MARK: FlyoutPlacement (AppKit coordinates, y up)

    static let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    static let popover = CGRect(x: 1000, y: 395, width: 360, height: 472)
    static let size = CGSize(width: 320, height: 200)

    @Test func placementLeftOfPopoverAlignedWithRow() {
        let row = CGRect(x: 1007, y: 700, width: 346, height: 44)
        let f = FlyoutPlacement.frame(rowRect: row, popoverFrame: Self.popover, visibleFrame: Self.visible,
                                      size: Self.size, gap: 6)
        #expect(f == CGRect(x: 1000 - 6 - 320, y: 744 - 200, width: 320, height: 200))
    }

    @Test func placementFallsBackRight() {
        let popover = CGRect(x: 100, y: 395, width: 360, height: 472)
        let row = CGRect(x: 107, y: 700, width: 346, height: 44)
        let f = FlyoutPlacement.frame(rowRect: row, popoverFrame: popover, visibleFrame: Self.visible,
                                      size: Self.size, gap: 6)
        #expect(f.minX == 466)
        #expect(f.maxY == 744)
    }

    @Test func placementClampedToScreenBottomAndTop() {
        let low = CGRect(x: 1007, y: 60, width: 346, height: 44)       // row near the bottom: flyout pushed up
        let b = FlyoutPlacement.frame(rowRect: low, popoverFrame: Self.popover, visibleFrame: Self.visible,
                                      size: Self.size, gap: 6)
        #expect(b.minY == 8)
        #expect(b.height == 200)
        let high = CGRect(x: 1007, y: 860, width: 346, height: 44)     // row top above the visible top
        let t = FlyoutPlacement.frame(rowRect: high, popoverFrame: Self.popover, visibleFrame: Self.visible,
                                      size: Self.size, gap: 6)
        #expect(t.maxY == 867)                                         // visible top 875 − margin 8
        let tall = FlyoutPlacement.frame(rowRect: high, popoverFrame: Self.popover, visibleFrame: Self.visible,
                                         size: CGSize(width: 320, height: 2000), gap: 6)
        #expect(tall.minY == 8 && tall.maxY == 867)                    // taller than the screen: capped
    }

    // MARK: HoverIntent

    /// Manual clock: timers fire only when the test advances time.
    @MainActor final class FakeClock {
        struct Timer {
            var id: Int
            var deadline: Duration
            var action: @MainActor () -> Void
        }
        var now: Duration = .zero
        var timers: [Timer] = []
        var nextID = 0

        func schedule(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            nextID += 1
            let id = nextID
            timers.append(Timer(id: id, deadline: now + delay, action: action))
            return { [weak self] in self?.timers.removeAll { $0.id == id } }
        }

        func advance(_ d: Duration) {
            let end = now + d
            while let next = timers.filter({ $0.deadline <= end }).min(by: { $0.deadline < $1.deadline }) {
                timers.removeAll { $0.id == next.id }
                now = next.deadline
                next.action()
            }
            now = end
        }
    }

    final class Recorder {
        var events: [String] = []
    }

    static func intent(_ clock: FakeClock, _ rec: Recorder) -> HoverIntent<MonitorModel.Category> {
        let i = HoverIntent<MonitorModel.Category>(schedule: { clock.schedule($0, $1) })
        i.onShow = { rec.events.append("show \($0)") }
        i.onHide = { rec.events.append("hide") }
        return i
    }

    @Test func opensAfterDelay() {
        let clock = FakeClock(), rec = Recorder(), i = Self.intent(clock, rec)
        i.rowEntered(.cpu)
        clock.advance(.milliseconds(249))
        #expect(rec.events.isEmpty && i.shown == nil)
        clock.advance(.milliseconds(1))
        #expect(rec.events == ["show cpu"] && i.shown == .cpu)

        // Passing over a row faster than the delay opens nothing.
        let r2 = Recorder(), i2 = Self.intent(clock, r2)
        i2.rowEntered(.gpu)
        clock.advance(.milliseconds(100))
        i2.rowExited(.gpu)
        clock.advance(.seconds(1))
        #expect(r2.events.isEmpty)
    }

    @Test func switchesRowsImmediately() {
        let clock = FakeClock(), rec = Recorder(), i = Self.intent(clock, rec)
        i.rowEntered(.cpu)
        clock.advance(.milliseconds(250))
        i.rowExited(.cpu)
        i.rowEntered(.memory)                           // no delay once open
        #expect(rec.events == ["show cpu", "show memory"])
        i.rowEntered(.gpu)                              // enter before the previous exit (either order)
        i.rowExited(.memory)
        clock.advance(.seconds(1))
        #expect(rec.events == ["show cpu", "show memory", "show gpu"] && i.shown == .gpu)
    }

    @Test func closesAfterGrace() {
        let clock = FakeClock(), rec = Recorder(), i = Self.intent(clock, rec)
        i.rowEntered(.cpu)
        clock.advance(.milliseconds(300))
        i.rowExited(.cpu)
        clock.advance(.milliseconds(199))
        #expect(i.shown == .cpu)
        clock.advance(.milliseconds(1))
        #expect(rec.events == ["show cpu", "hide"] && i.shown == nil)
    }

    @Test func flyoutHoverBridgesTheGap() {
        let clock = FakeClock(), rec = Recorder(), i = Self.intent(clock, rec)
        i.rowEntered(.cpu)
        clock.advance(.milliseconds(250))
        i.rowExited(.cpu)
        clock.advance(.milliseconds(150))
        i.flyoutHover(true)
        clock.advance(.seconds(2))
        #expect(i.shown == .cpu)
        i.flyoutHover(false)
        clock.advance(.milliseconds(100))
        i.rowEntered(.cpu)                              // back onto the row within the grace: stays open
        clock.advance(.seconds(1))
        #expect(rec.events == ["show cpu"])
        i.rowExited(.cpu)
        i.flyoutHover(true)
        i.flyoutHover(false)
        clock.advance(.milliseconds(200))
        #expect(rec.events == ["show cpu", "hide"])
    }

    @Test func showNowAndDismiss() {
        let clock = FakeClock(), rec = Recorder(), i = Self.intent(clock, rec)
        i.showNow(.thermals)                            // "Show top apps" accessibility action
        #expect(rec.events == ["show thermals"])
        i.rowEntered(.cpu)
        #expect(rec.events == ["show thermals", "show cpu"])
        i.dismiss()                                     // popover closed
        #expect(rec.events == ["show thermals", "show cpu", "hide"] && i.shown == nil)
        i.rowEntered(.gpu)
        i.dismiss()                                     // pending open cancelled
        clock.advance(.seconds(1))
        #expect(rec.events == ["show thermals", "show cpu", "hide"])
    }

    // MARK: Snapshots

    static let canvas = CGSize(width: 340, height: 360)

    func flyout(_ category: MonitorModel.Category, _ ctx: ShellContext) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            FlyoutView(category: category).padding(10)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
        .telltaleEnvironment(ctx)
    }

    static func context(apps: [AppSample]) -> ShellContext {
        var ctx = ScreenFixture.context(.calm)
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        var f = provider.frame(at: 60)
        f.apps = apps
        live.apply(f)
        live.isPresenting = true
        ctx.live = live
        return ctx
    }

    @Test func snapshots() {
        assertSnapshot(flyout(.cpu, ScreenFixture.context(.calm)), size: Self.canvas, named: "flyout-cpu-calm")
        assertSnapshot(flyout(.memory, ScreenFixture.context(.calm)), size: Self.canvas, named: "flyout-memory-calm")
        assertSnapshot(flyout(.thermals, ScreenFixture.context(.calm)), size: Self.canvas, named: "flyout-thermals")
        let few = [Self.app("Xcode", cpu: 62.5), Self.app("A Very Long Application Name That Truncates Helper", cpu: 20),
                   Self.app("Safari", cpu: 5)]
        assertSnapshot(flyout(.cpu, Self.context(apps: few)), size: Self.canvas, named: "flyout-few-apps")
        assertSnapshot(flyout(.cpu, Self.context(apps: [])), size: Self.canvas, named: "flyout-empty")
    }
}
