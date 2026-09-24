import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// DESIGN §3.10 Power & Battery goldens (`__Snapshots__/power-*.png`).
@MainActor
@Suite("PowerSnapshotTests", .enabled { await ScreenFixture.snapshotsAvailable })
struct PowerSnapshotTests {
    // collecting is identical to calm here (firstTick covers "Collecting…").
    @Test func calm() { assertScreen("power", scenario: .calm) }
    @Test func sensorsUnavailable() { assertScreen("power", scenario: .sensorsUnavailable) }
    @Test func restricted() { assertScreen("power", scenario: .restricted) }

    /// Force Quit confirm (TTConfirmDialog over the page area).
    @Test func forceQuitConfirm() {
        let feedback = ProcessActionFeedback()
        let fcp = AppIdentity(key: AppKey(kind: .app, id: "com.apple.FinalCut"), displayName: "Final Cut Pro")
        feedback.requestForceQuit?(.app(fcp, pids: [812]))
        assertSnapshot(PowerPage(selectedRowID: nil, feedback: feedback).screenEnvironment(.calm, page: .power),
                       size: ScreenSize.pageContent, named: "power-forcequit-calm")
    }

    /// First tick: one sample → chart "Collecting…", values already shown.
    @Test func firstTick() {
        assertSnapshot(PowerPage().telltaleEnvironment(ScreenFixture.context(.collecting, page: .power, ticks: 0)),
                       size: ScreenSize.pageContent, named: "power-firsttick-collecting")
    }

    /// A selected user-owned row shows inline [Quit] [Force Quit] (leading) instead of "…".
    @Test func selectedRowInlineActions() {
        var ctx = ScreenFixture.context(.calm, page: .power)
        ctx.processActions = ProcessActions(canControl: { _ in true })
        assertSnapshot(PowerPage(selectedRowID: "app:app:com.apple.FinalCut").telltaleEnvironment(ctx),
                       size: ScreenSize.pageContent, named: "power-selected-calm")
    }

    /// CP2: a MacBook whose battery sensor is unavailable keeps the battery layout with "—" + the reason
    /// (never "No battery").
    @Test func laptopBatterySensorUnavailable() {
        let provider = MockDataProvider(scenario: .calm)
        var device = provider.device
        device.hasBattery = true
        let live = LiveModel(device: device)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.device = device
            f.power.battery = nil
            f.sensorHealth[.battery] = .unavailable("AppleSmartBattery not found")
            live.apply(f)
        }
        live.isPresenting = true
        let ctx = ShellContext(live: live, settings: ScreenCatalog.snapshotSettings(), history: provider.history(),
                               isSnapshot: true, now: MockDataProvider.referenceDate)
        assertSnapshot(PowerPage().telltaleEnvironment(ctx), size: ScreenSize.pageContent,
                       named: "power-battery-unavailable")
    }

    /// Desktop Mac: no battery → "No battery" card, drain "—", header without Wh.
    @Test func desktopNoBattery() {
        let provider = MockDataProvider(scenario: .calm)
        var device = provider.device
        device.hasBattery = false
        let live = LiveModel(device: device)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.device = device
            f.power.battery = nil
            f.power.adapterWatts = 140
            live.apply(f)
        }
        live.isPresenting = true
        let ctx = ShellContext(live: live, settings: ScreenCatalog.snapshotSettings(), history: provider.history(),
                               isSnapshot: true, now: MockDataProvider.referenceDate)
        ctx.navigation.page = .power
        assertSnapshot(DashboardRoot().frame(width: 1280, height: 860).telltaleEnvironment(ctx),
                       size: ScreenSize.dashboard, named: "power-desktop-calm")
    }
}

/// Records action calls (main-actor only).
@MainActor final class PowerDiskCallLog {
    var calls: [ProcessTarget] = []
    var volumes: [String] = []
}

@MainActor
@Suite("PowerPageLogicTests")
struct PowerPageLogicTests {
    private func battery(onAC: Bool = false, charging: Bool = false, drain: Double? = -18.9,
                         percent: Double = 82, remaining: Duration? = .seconds(5 * 3600 + 40 * 60)) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isCharging: charging, onAC: onAC, timeRemaining: remaining,
                        designCapacityWh: 72.4, drainWatts: drain)
    }

    @Test func subtitle() {
        #expect(PowerCopy.subtitle(PowerSnapshot(battery: battery(), lowPowerMode: false), hasBattery: true)
            == "On battery · 72.4 Wh · Low Power Mode off")
        #expect(PowerCopy.subtitle(PowerSnapshot(battery: battery(onAC: true), adapterWatts: 96, lowPowerMode: true),
                                   hasBattery: true)
            == "On power adapter · 96 W · 72.4 Wh · Low Power Mode on")
        #expect(PowerCopy.subtitle(PowerSnapshot(lowPowerMode: false), hasBattery: false)
            == "On power adapter · Low Power Mode off")
        // Laptop with the battery sensor down: no power-source claim.
        #expect(PowerCopy.subtitle(PowerSnapshot(lowPowerMode: false), hasBattery: true) == "Low Power Mode off")
    }

    /// CP2: "No battery" only when the Mac has none; otherwise the battery sensor's reason.
    @Test func batteryReason() {
        #expect(PowerCopy.batteryReason(hasBattery: false, status: .ok) == "This Mac has no battery")
        #expect(PowerCopy.batteryReason(hasBattery: true, status: .unavailable("AppleSmartBattery not found"))
            == "AppleSmartBattery not found")
        #expect(PowerCopy.batteryReason(hasBattery: true, status: .ok) == "Not reported by the battery")
    }

    @Test func drain() {
        #expect(PowerCopy.drain(battery()) == "\u{2212}18.9 W")
        #expect(PowerCopy.drain(battery(onAC: true, charging: true, drain: 12)) == "+12.0 W")
        #expect(PowerCopy.drain(battery(onAC: true, charging: false, drain: 0.01)) == "0.0 W")
        #expect(PowerCopy.drain(battery(drain: nil)) == nil)
    }

    @Test func batteryPhrase() {
        #expect(PowerCopy.batteryPhrase(battery()) == "On battery · about 5 h 40 m left")
        #expect(PowerCopy.batteryPhrase(battery(onAC: true, charging: true, remaining: .seconds(70 * 60)))
            == "Charging · full in 1 h 10 m")
        #expect(PowerCopy.batteryPhrase(battery(onAC: true, percent: 100, remaining: nil)) == "Charged")
        #expect(PowerCopy.batteryPhrase(battery(remaining: nil)) == "On battery")
        // ICR-15: macOS still estimating.
        var calc = battery(remaining: nil)
        calc.timeRemainingCalculating = true
        #expect(PowerCopy.batteryPhrase(calc) == "On battery · Calculating…")
        calc.isCharging = true
        calc.onAC = true
        #expect(PowerCopy.batteryPhrase(calc) == "Charging · Calculating…")
    }

    /// ICR-15 on the Battery card.
    @Test func calculatingSnapshot() {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.power.battery?.timeRemaining = nil
            f.power.battery?.timeRemainingCalculating = true
            live.apply(f)
        }
        live.isPresenting = true
        let ctx = ShellContext(live: live, settings: ScreenCatalog.snapshotSettings(), history: provider.history(),
                               isSnapshot: true, now: MockDataProvider.referenceDate)
        assertSnapshot(PowerPage().telltaleEnvironment(ctx), size: ScreenSize.pageContent, named: "power-calculating")
    }

    @Test func adapterAndFill() {
        #expect(PowerCopy.adapter(PowerSnapshot(battery: battery(), lowPowerMode: false)) == "Not connected")
        #expect(PowerCopy.adapter(PowerSnapshot(battery: battery(onAC: true), adapterWatts: 96, adapterName: "USB-C",
                                                lowPowerMode: false)) == "96 W USB-C")
        // Battery sensor down: adapter details still show; unknown state is "—" (never the battery's reason).
        #expect(PowerCopy.adapter(PowerSnapshot(adapterWatts: 140, lowPowerMode: false)) == "140 W")
        #expect(PowerCopy.adapter(PowerSnapshot(lowPowerMode: false)) == nil)
        #expect(PowerCopy.adapter(PowerSnapshot(battery: battery(onAC: true), lowPowerMode: false)) == "Connected")
        #expect(PowerCopy.fillColor(percent: 82) == TTColor.battery)
        #expect(PowerCopy.fillColor(percent: 20) == TTColor.statusElevated)
        #expect(PowerCopy.fillColor(percent: 10) == TTColor.statusCritical)
    }

    @Test func chartCeilingStacksNewestAligned() {
        let t = Date(timeIntervalSince1970: 0)
        let a = [SeriesPoint(time: t, value: 10), SeriesPoint(time: t, value: 12)]
        let b = [SeriesPoint(time: t, value: 5)]                 // aligns with a's last sample → 17
        #expect(PowerChartScale.ceiling([a, b]) == 20)
        #expect(PowerChartScale.ceiling([[]]) == 1)
    }

    /// Force Quit always confirms: request → pending dialog; Cancel clears; confirm runs forceQuit and toasts.
    @Test func forceQuitConfirmFlow() async {
        let feedback = ProcessActionFeedback()
        let target = ProcessTarget.process(pid: 42, name: "ffmpeg", path: nil, uid: 501)
        let log = PowerDiskCallLog()
        let actions = ProcessActions(canControl: { _ in true },
                                     forceQuit: { t in log.calls.append(t); return .done })
        feedback.requestForceQuit?(target)
        #expect(feedback.pending == .init(target: target, name: "ffmpeg"))
        feedback.cancel()
        #expect(feedback.pending == nil)
        await feedback.confirm(using: actions)
        #expect(log.calls.isEmpty)                                  // nothing pending → no action
        feedback.requestForceQuit?(target)
        await feedback.confirm(using: actions)
        #expect(log.calls == [target])
        #expect(feedback.pending == nil)
        #expect(feedback.toast == "ffmpeg was force quit.")
        feedback.onResult?(target, .notPermitted)
        #expect(feedback.toast == "Not permitted to quit ffmpeg.")
        feedback.onResult?(target, .cancelled)                       // cancelled keeps the previous toast
        #expect(feedback.toast == "Not permitted to quit ffmpeg.")
    }

    /// Handlers are created once (stable environment values → row menus aren't invalidated per tick).
    @Test func feedbackHandlersAreStable() {
        let feedback = ProcessActionFeedback()
        #expect(feedback.requestForceQuit != nil && feedback.onResult != nil)
    }

    @Test func energyRowsFilterAndTargets() {
        let fcp = AppIdentity(key: AppKey(kind: .app, id: "fcp"), displayName: "Final Cut Pro")
        let idle = AppIdentity(key: AppKey(kind: .app, id: "idle"), displayName: "Idle")
        let sleepy = AppIdentity(key: AppKey(kind: .app, id: "sleepy"), displayName: "Sleepy")
        let apps = [
            AppSample(identity: fcp, energyWatts: 7.15, energyEstimated: true),
            AppSample(identity: idle, energyWatts: 0),
            AppSample(identity: sleepy, energyWatts: 0, preventsSleep: true),
            AppSample(identity: AppIdentity(key: .other, displayName: "Other"), energyWatts: 3),
        ]
        let rows = EnergyRows.apps(apps.reversed(), averages: [fcp.key: 5.2], health: [:])
        #expect(rows.map(\.name) == ["Final Cut Pro", "Sleepy"])        // sorted by energy, descending
        #expect(rows[0].estimated && rows[0].average12h == 5.2 && rows[0].reason == nil)
        #expect(rows[0].target == .app(fcp, pids: []))
    }
}
