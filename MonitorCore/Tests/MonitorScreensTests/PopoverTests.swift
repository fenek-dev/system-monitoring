import Foundation
import MonitorLive
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

    @Test func thermalAlertStressesRowAndBanner() {
        let live = ScreenFixture.live(.thermalFair)
        let units = UnitPreferences()
        let row = PopoverModel.row(.thermals, live: live, units: units)
        #expect(row.stress == .elevated)
        #expect(row.subtitle?.hasPrefix("Fair · fans ") == true)
        let banners = PopoverModel.banners(live: live, units: units, canControl: { _ in true })
        #expect(banners.count == live.alert.active.count)
        let first = try? #require(banners.first)
        #expect(first?.message.contains("is pushing the SoC to") == true)
        #expect(first?.buttons.first?.title == "Show Thermals")
        #expect(PopoverModel.banners(live: live, units: units, canControl: { _ in false })
            .first?.buttons.count == 1)
        #expect(PopoverModel.consumer(live: live)?.detail.contains("GPU") == true)
    }

    @Test func thermalSubtitleWithoutFans() {
        var device = DeviceInfo.placeholder
        device.fanCount = 0
        var t = SystemFrame.empty.thermals
        t.pressure = .nominal
        #expect(PopoverModel.thermalSubtitle(t, device: device, stressed: false) == "Nominal · no fans")
    }

    @Test func expansionShowsTopThree() {
        let live = ScreenFixture.live(.calm)
        let apps = PopoverModel.expansionApps(.cpu, live: live)
        #expect(apps.count == 3)
        #expect(zip(apps, apps.dropFirst()).allSatisfy { ($0.cpuPercent ?? 0) >= ($1.cpuPercent ?? 0) })
    }

    // MARK: Behaviour (recording AppCommands + mock ActionLog)

    final class CommandLog: @unchecked Sendable {
        var entries: [String] = []
    }

    static func recording(_ log: CommandLog) -> AppCommands {
        AppCommands(openDashboard: { log.entries.append("open \($0?.rawValue ?? "nil")") },
                    inspectApp: { log.entries.append("inspect \($0.id)") },
                    openSettings: { log.entries.append("settings") },
                    setPaused: { log.entries.append("paused \($0)") },
                    quitTelltale: { log.entries.append("quitTelltale") })
    }

    @Test func bannerButtonsShowPageAndQuitCulprit() async {
        let live = ScreenFixture.live(.thermalFair)
        let log = CommandLog()
        let actionLog = ActionLog()
        let actions = MockDataProvider(scenario: .thermalFair).processActions(log: actionLog)
        let ops = PopoverActions(commands: Self.recording(log), actions: actions, live: live)
        let banner = try? #require(PopoverModel.banners(live: live, units: UnitPreferences(),
                                                        canControl: actions.canControl).first)
        #expect(banner?.buttons.map(\.title) == ["Show Thermals", "Quit Final Cut Pro"])
        for b in banner?.buttons ?? [] { _ = await ops.perform(b.action) }
        #expect(log.entries == ["open thermals"])
        #expect(actionLog.entries == ["quit Final Cut Pro -> done"])
    }

    @Test func footerAndRowCommands() {
        let log = CommandLog()
        let live = ScreenFixture.live(.calm)
        let ops = PopoverActions(commands: Self.recording(log), actions: .noop, live: live)
        ops.openDashboard()
        ops.openHistory()
        ops.quitTelltale()
        ops.openApp(AppKey(kind: .app, id: "com.apple.dt.Xcode"))   // top-consumer click
        ops.setPaused(true)
        ops.openSettings()
        #expect(log.entries == ["open overview", "open history", "quitTelltale",
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

    @Test func topConsumerQuitAndFeedback() async {
        let live = ScreenFixture.live(.calm)
        let actionLog = ActionLog()
        let actions = MockDataProvider(scenario: .calm).processActions(log: actionLog)
        let ops = PopoverActions(commands: .noop, actions: actions, live: live)
        let consumer = try? #require(PopoverModel.consumer(live: live))
        #expect(consumer?.app.name == "Xcode")
        if let app = consumer?.app { #expect(await ops.quit(app) == nil) }
        #expect(actionLog.entries == ["quit Xcode -> done"])
        #expect(PopoverModel.feedback(.notPermitted, name: "WindowServer") == "Not permitted to quit WindowServer")
    }

    // MARK: Invalidation

    /// A memory-only update (no new sample) must not invalidate the CPU or Power rows' observed reads.
    @Test func memoryOnlyChangeDoesNotTouchOtherRows() {
        let provider = MockDataProvider(scenario: .calm)
        let live = ScreenFixture.live(.calm)
        let units = UnitPreferences()
        final class Flag: @unchecked Sendable { var fired = false }
        var flags: [MonitorModel.Category: Flag] = [:]
        for c in [MonitorModel.Category.cpu, .power, .memory] {
            let flag = Flag()
            flags[c] = flag
            withObservationTracking { _ = PopoverModel.row(c, live: live, units: units) } onChange: { flag.fired = true }
        }
        var f = provider.frame(at: 60)                       // same sample time as the last applied frame
        f.memory.used = (f.memory.used ?? 0) + 1_073_741_824
        live.apply(f)
        #expect(flags[.memory]?.fired == true)
        #expect(flags[.cpu]?.fired == false)
        #expect(flags[.power]?.fired == false)
    }

    @Test func snapshots() {
        assertScreen("popover", scenario: .calm)
        assertScreen("popover-alert", scenario: .thermalFair)
        assertScreen("popover", scenario: .sensorsUnavailable)
        assertScreen("popover", scenario: .collecting)
        assertScreen("popover", scenario: .paused)
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
