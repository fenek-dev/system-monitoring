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
    @Test func calm() { assertScreen("power", scenario: .calm) }
    @Test func sensorsUnavailable() { assertScreen("power", scenario: .sensorsUnavailable) }
    @Test func collecting() { assertScreen("power", scenario: .collecting) }
    @Test func restricted() { assertScreen("power", scenario: .restricted) }

    /// A selected user-owned row shows inline [Quit] [Force Quit] (leading) instead of "…".
    @Test func selectedRowInlineActions() {
        var ctx = ScreenFixture.context(.calm, page: .power)
        ctx.processActions = ProcessActions(canControl: { _ in true })
        assertSnapshot(PowerPage(selectedRowID: "app:app:com.apple.FinalCut").telltaleEnvironment(ctx),
                       size: ScreenSize.pageContent, named: "power-selected-calm")
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

@MainActor
@Suite("PowerPageLogicTests")
struct PowerPageLogicTests {
    private func battery(onAC: Bool = false, charging: Bool = false, drain: Double? = -18.9,
                         percent: Double = 82, remaining: Duration? = .seconds(5 * 3600 + 40 * 60)) -> BatterySnapshot {
        BatterySnapshot(percent: percent, isCharging: charging, onAC: onAC, timeRemaining: remaining,
                        designCapacityWh: 72.4, drainWatts: drain)
    }

    @Test func subtitle() {
        #expect(PowerCopy.subtitle(PowerSnapshot(battery: battery(), lowPowerMode: false))
            == "On battery · 72.4 Wh · Low Power Mode off")
        #expect(PowerCopy.subtitle(PowerSnapshot(battery: battery(onAC: true), adapterWatts: 96, lowPowerMode: true))
            == "On power adapter · 96 W · 72.4 Wh · Low Power Mode on")
        #expect(PowerCopy.subtitle(PowerSnapshot(lowPowerMode: false)) == "On power adapter · Low Power Mode off")
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
    }

    @Test func adapterAndFill() {
        #expect(PowerCopy.adapter(PowerSnapshot(battery: battery(), lowPowerMode: false)) == "Not connected")
        #expect(PowerCopy.adapter(PowerSnapshot(battery: battery(onAC: true), adapterWatts: 96, adapterName: "USB-C",
                                                lowPowerMode: false)) == "96 W USB-C")
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
        let rows = EnergyRows.apps(apps, averages: [fcp.key: 5.2], health: [:])
        #expect(rows.map(\.name) == ["Final Cut Pro", "Sleepy"])
        #expect(rows[0].estimated && rows[0].average12h == 5.2 && rows[0].reason == nil)
        #expect(rows[0].target == .app(fcp, pids: []))
    }
}
