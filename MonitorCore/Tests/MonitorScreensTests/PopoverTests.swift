import Foundation
import MonitorLive
import os
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("Popover")
@MainActor
struct PopoverTests {
    @Test func sectionsFollowLayoutOrderAndHidden() {
        let def = PopoverModel.sections(PopoverLayout())
        #expect(def.full == [.cpu, .gpu, .memory, .network, .thermals])
        #expect(def.compact == [.power, .disk])

        let custom = PopoverModel.sections(PopoverLayout(order: [.disk, .thermals, .cpu, .power, .gpu, .memory, .network],
                                                         hidden: [.gpu, .power]))
        #expect(custom.full == [.thermals, .cpu, .memory, .network])
        #expect(custom.compact == [.disk])

        let noCompact = PopoverModel.sections(PopoverLayout(hidden: [.power, .disk]))
        #expect(noCompact.compact.isEmpty)
    }

    @Test func calmRowBindings() {
        let live = ScreenFixture.live(.calm)
        let units = UnitPreferences()
        let cpu = PopoverModel.row(.cpu, live: live, units: units)
        #expect(cpu.subtitle == "12 cores · 4.1 GHz")
        #expect(cpu.value?.hasSuffix("%") == true)
        #expect(cpu.stress == .calm)
        #expect(PopoverModel.row(.memory, live: live, units: units).subtitle == "pressure normal")
        #expect(PopoverModel.row(.network, live: live, units: units).subtitle?.hasPrefix("↑ ") == true)
        #expect(PopoverModel.row(.thermals, live: live, units: units).subtitle?.hasPrefix("Nominal · ") == true)
        #expect(PopoverModel.row(.power, live: live, units: units).subtitle == "82% · 5 h 40 m left")
        #expect(PopoverModel.row(.disk, live: live, units: units).subtitle?.hasPrefix("R ") == true)
        let mem = PopoverModel.row(.memory, live: live, units: units)
        #expect(mem.domain.upperBound == Double(live.memory.total))
    }

    @Test func thermalAlertStressesRowAndBanner() throws {
        let live = ScreenFixture.live(.thermalFair)
        let units = UnitPreferences()
        let row = PopoverModel.row(.thermals, live: live, units: units)
        #expect(row.stress == .elevated)
        #expect(row.subtitle?.hasPrefix("Fair · fans ") == true)
        let banners = PopoverModel.banners(live: live, units: units, canControl: { _ in true })
        #expect(banners.count == live.alert.active.count)
        let first = try #require(banners.first)
        #expect(first.message.contains("is pushing the SoC to"))
        #expect(first.buttons.first?.title == "Show Thermals")
        #expect(PopoverModel.banners(live: live, units: units, canControl: { _ in false })
            .first?.buttons.count == 1)
        #expect(PopoverModel.consumer(live: live)?.detail.contains("GPU") == true)
    }

    /// CP2: the Power row shows watts whenever the Mac reports any (component sum, else SMC system power), and Disk
    /// shows available capacity (not purgeable-inclusive "important usage").
    @Test func powerAndDiskRowsCP2() {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        var f = provider.frame(at: 60)
        f.power.packageWatts = nil
        f.power.cpuWatts = nil
        f.power.gpuWatts = nil
        f.power.aneWatts = nil
        f.power.dramWatts = nil
        f.power.systemWatts = 5.8
        f.disk.volumes = f.disk.volumes.map { v in
            var v = v
            v.availableBytes = 1_090_000_000_000
            v.availableImportantBytes = 1_180_000_000_000
            return v
        }
        live.apply(f)
        live.isPresenting = true
        #expect(PopoverModel.row(.power, live: live, units: UnitPreferences()).value == "5.8 W")
        #expect(PopoverModel.row(.disk, live: live, units: UnitPreferences()).value == "1.09 TB")
    }

    @Test func thermalSubtitleWithoutFans() {
        var device = DeviceInfo.placeholder
        device.fanCount = 0
        var t = SystemFrame.empty.thermals
        t.pressure = .nominal
        #expect(PopoverModel.thermalSubtitle(t, device: device, stressed: false) == "Nominal · no fans")
    }

    /// U-I2: an unknown fan count (SMC unreachable / placeholder) is not "no fans"; an unknown battery is not
    /// "AC power" — before the first frame nothing is claimed.
    @Test func unknownDeviceFactsAreNotFacts() {
        var t = SystemFrame.empty.thermals
        t.pressure = .nominal
        #expect(DeviceInfo.placeholder.fanCount == nil && DeviceInfo.placeholder.hasBattery == nil)
        #expect(PopoverModel.thermalSubtitle(t, device: .placeholder, stressed: false) == "Nominal")

        let fresh = LiveModel()                      // before the first frame
        fresh.isPresenting = true
        #expect(PopoverModel.row(.power, live: fresh, units: UnitPreferences()).subtitle == nil)
        #expect(PopoverModel.row(.thermals, live: fresh, units: UnitPreferences()).subtitle?.contains("no fans") != true)

        let unknown = ScreenFixture.live(.deviceUnknown)
        #expect(unknown.device.fanCount == nil && unknown.device.hasBattery == nil)
        #expect(PopoverModel.row(.power, live: unknown, units: UnitPreferences()).subtitle == nil)
        #expect(PopoverModel.row(.thermals, live: unknown, units: UnitPreferences()).subtitle == "Nominal")

        var desktop = DeviceInfo.placeholder
        desktop.hasBattery = false
        #expect(PopoverModel.powerPhrase(PowerSnapshot(), device: desktop, lastUpdate: Date()) == W5a.batteryPhrase(nil))
        #expect(PopoverModel.powerPhrase(PowerSnapshot(), device: desktop, lastUpdate: nil) == nil)
        #expect(PowerCopy.batteryReason(hasBattery: nil, status: .ok) == "Collecting…")
        #expect(!PowerCopy.subtitle(PowerSnapshot(lowPowerMode: false), hasBattery: nil).contains("adapter"))
    }

    @Test func expansionShowsTopThree() {
        let live = ScreenFixture.live(.calm)
        let apps = PopoverModel.expansionApps(.cpu, live: live)
        #expect(apps.count == 3)
        #expect(zip(apps, apps.dropFirst()).allSatisfy { ($0.cpuPercent ?? 0) >= ($1.cpuPercent ?? 0) })
    }

    // MARK: Behaviour (recording AppCommands + mock ActionLog)

    /// Lock-protected command recorder (Sendable without an unchecked escape hatch).
    typealias CommandLog = OSAllocatedUnfairLock<[String]>

    static func recording(_ log: CommandLog) -> AppCommands {
        AppCommands(openDashboard: { p in log.withLock { $0.append("open \(p?.rawValue ?? "nil")") } },
                    inspectApp: { k in log.withLock { $0.append("inspect \(k.id)") } },
                    openSettings: { log.withLock { $0.append("settings") } },
                    setPaused: { v in log.withLock { $0.append("paused \(v)") } },
                    quitTelltale: { log.withLock { $0.append("quitTelltale") } })
    }

    @Test func bannerButtonsShowPageAndQuitCulprit() async throws {
        let live = ScreenFixture.live(.thermalFair)
        let log = CommandLog(initialState: [])
        let actionLog = ActionLog()
        let actions = MockDataProvider(scenario: .thermalFair).processActions(log: actionLog)
        let ops = PopoverActions(commands: Self.recording(log), actions: actions, live: live)
        let banner = try #require(PopoverModel.banners(live: live, units: UnitPreferences(),
                                                       canControl: actions.canControl).first)
        #expect(banner.buttons.map(\.title) == ["Show Thermals", "Quit Final Cut Pro"])
        for b in banner.buttons { _ = await ops.perform(b.action) }
        let entries = log.withLock { $0 }
        #expect(entries == ["open thermals"])
        #expect(actionLog.entries == ["quit Final Cut Pro -> done"])
    }

    @Test func footerAndRowCommands() {
        let log = CommandLog(initialState: [])
        let live = ScreenFixture.live(.calm)
        let ops = PopoverActions(commands: Self.recording(log), actions: .noop, live: live)
        ops.openDashboard()
        ops.openHistory()
        ops.quitTelltale()
        ops.openApp(AppKey(kind: .app, id: "com.apple.dt.Xcode"))   // top-consumer click
        ops.setPaused(true)
        ops.openSettings()
        #expect(log.withLock { $0 } == ["open overview", "open history", "quitTelltale",
                                         "inspect com.apple.dt.Xcode", "paused true", "settings"])
        // Row double-click / expansion-line clicks are TTPopoverRow's (W3), via the same `appCommands`.
    }

    @Test func rowExpansionToggles() {
        var open: Set<MonitorModel.Category> = []
        open = PopoverModel.toggled(open, .cpu)
        open = PopoverModel.toggled(open, .memory)
        #expect(open == [.cpu, .memory])            // several rows may be open at once
        open = PopoverModel.toggled(open, .cpu)
        #expect(open == [.memory])
    }

    @Test func topConsumerQuitAndFeedback() async throws {
        let live = ScreenFixture.live(.calm)
        let actionLog = ActionLog()
        let actions = MockDataProvider(scenario: .calm).processActions(log: actionLog)
        let ops = PopoverActions(commands: .noop, actions: actions, live: live)
        let consumer = try #require(PopoverModel.consumer(live: live))
        #expect(consumer.app.name == "Xcode")
        #expect(await ops.quit(consumer.app) == nil)
        #expect(actionLog.entries == ["quit Xcode -> done"])
        #expect(PopoverModel.feedback(.notPermitted, name: "WindowServer") == "Not permitted to quit WindowServer")
    }

    // MARK: Invalidation

    /// A memory-only update (no new sample) must not invalidate the CPU or Power rows' observed reads.
    @Test func memoryOnlyChangeDoesNotTouchOtherRows() {
        let provider = MockDataProvider(scenario: .calm)
        let live = ScreenFixture.live(.calm)
        let units = UnitPreferences()
        let fired = OSAllocatedUnfairLock<Set<MonitorModel.Category>>(initialState: [])
        for c in [MonitorModel.Category.cpu, .power, .memory] {
            withObservationTracking { _ = PopoverModel.row(c, live: live, units: units) } onChange: {
                fired.withLock { _ = $0.insert(c) }
            }
        }
        var f = provider.frame(at: 60)                       // same sample time as the last applied frame
        f.memory.used = (f.memory.used ?? 0) + 1_073_741_824
        live.apply(f)
        #expect(fired.withLock { $0 } == [.memory])
    }

    /// B8: the calm top consumer is the first non-system group of the full CPU ranking; no energy fallback.
    @Test func topConsumerIsHighestCPUNonSystem() throws {
        let live = ScreenFixture.live(.calm)
        let consumer = try #require(PopoverModel.consumer(live: live))
        let best = live.apps.filter { $0.identity.key.kind != .system && $0.identity.key != .other }
            .max { ($0.cpuPercent ?? -1) < ($1.cpuPercent ?? -1) }
        #expect(consumer.app.identity.key == best?.identity.key)
    }

    @Test func snapshots() {
        assertScreen("popover", scenario: .calm)
        assertScreen("popover-alert", scenario: .thermalFair)
        assertScreen("popover", scenario: .sensorsUnavailable)
        assertScreen("popover", scenario: .collecting)
        assertScreen("popover", scenario: .paused)
        assertScreen("popover", scenario: .deviceUnknown)
    }

    @Test func expandedSnapshot() {
        let view = ZStack(alignment: .topLeading) {
            Color.black
            PopoverContainer { PopoverRoot(expanded: [.cpu, .thermals]) }.offset(x: 68, y: 34)
        }
        .frame(width: 440, height: 900, alignment: .topLeading)
        .screenEnvironment(.calm)
        assertSnapshot(view, size: CGSize(width: 440, height: 900), named: "popover-expanded-calm")
    }
}
