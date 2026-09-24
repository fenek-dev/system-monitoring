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
        let lines = PopoverModel.expansion(.cpu, live: live, units: UnitPreferences())
        #expect(lines.count == 3)
        #expect(lines.allSatisfy { $0.value.hasSuffix("%") })
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
