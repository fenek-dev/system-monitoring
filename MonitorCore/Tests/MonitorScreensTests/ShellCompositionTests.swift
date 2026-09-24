import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("Shell launch options")
struct ShellLaunchOptionsTests {
    @Test func defaults() {
        let o = LaunchOptions.parse(arguments: ["/x/Telltale"], environment: [:])
        #expect(o == LaunchOptions())
    }

    @Test func mockScenarioFromArgsAndEnv() {
        #expect(LaunchOptions.parse(arguments: ["--mock", "thermalFair"], environment: [:]).mockScenario == .thermalFair)
        #expect(LaunchOptions.parse(arguments: ["--mock"], environment: [:]).mockScenario == .calm)
        #expect(LaunchOptions.parse(arguments: ["--mock", "--open-popover"], environment: [:]) ==
            LaunchOptions(mockScenario: .calm, openPopover: true))
        #expect(LaunchOptions.parse(arguments: ["--mock", "nope"], environment: [:]).mockScenario == .calm)
        #expect(LaunchOptions.parse(arguments: [], environment: ["TELLTALE_MOCK": "runaway"]).mockScenario == .runaway)
        // argument wins over env
        #expect(LaunchOptions.parse(arguments: ["--mock", "paused"],
                                    environment: ["TELLTALE_MOCK": "runaway"]).mockScenario == .paused)
    }

    @Test func verificationArgs() {
        #expect(LaunchOptions.parse(arguments: ["--status-preview", "critical", "--open-settings"], environment: [:])
            == LaunchOptions(openSettings: true, statusPreview: .critical))
        #expect(LaunchOptions.parse(arguments: ["--status-preview"], environment: [:]).statusPreview == .elevated)
        #expect(LaunchOptions.parse(arguments: ["--login-item", "register"], environment: [:]).loginItemCommand == "register")
        #expect(LaunchOptions.parse(arguments: ["--login-item"], environment: [:]).loginItemCommand == "status")
    }

    @Test func openDashboardPage() {
        #expect(LaunchOptions.parse(arguments: ["--open-dashboard"], environment: [:]).openDashboard == .overview)
        #expect(LaunchOptions.parse(arguments: ["--open-dashboard", "thermals"], environment: [:]).openDashboard == .thermals)
    }

    @Test func dataDirDisabledSensorsCrashSensor() {
        let o = LaunchOptions.parse(arguments: ["--crash-sensor", "smc"],
                                    environment: ["TELLTALE_DATA_DIR": "/tmp/tt-data",
                                                  "TELLTALE_DISABLE_SENSORS": "coalitions, soc,bogus"])
        #expect(o.crashSensor == .smc)
        #expect(o.dataDirectory?.path == "/tmp/tt-data")
        #expect(o.disabledSensors == [.coalitions, .soc])
    }
}

@Suite("Shell settings store") @MainActor
struct ShellSettingsStoreTests {
    @Test func defaultsWhenEmpty() {
        let (s, _) = ScreenFixture.settings()
        #expect(s.units == UnitPreferences())
        #expect(s.popoverLayout == PopoverLayout())
        #expect(s.disabledSensors.isEmpty)
    }

    @Test func persistsAcrossInstances() {
        let (s, d) = ScreenFixture.settings()
        s.units.temperature = .fahrenheit
        s.setVisible(.gpu, false)
        s.moveRows(fromOffsets: [6], toOffset: 0)                  // disk first
        s.setDisabled(.smc, true)
        let s2 = SettingsStore(defaults: d)
        #expect(s2.units == UnitPreferences(temperature: .fahrenheit, networkRate: .bytes))
        #expect(s2.popoverLayout.order.first == .disk)
        #expect(s2.popoverLayout.hidden == [.gpu])
        #expect(s2.disabledSensors == [.smc])
        #expect(d.array(forKey: SettingsStore.Key.popoverRows)?.count == 7)
    }

    @Test func toleratesMissingAndGarbageKeys() {
        let (_, d) = ScreenFixture.settings()
        d.set("kelvin", forKey: SettingsStore.Key.temperature)       // unknown → default
        d.set("bits", forKey: SettingsStore.Key.networkRate)          // valid, temperature missing-equivalent
        d.set([["id": "memory", "visible": false], ["id": "bogus"], ["visible": true], "junk",
               ["id": "memory", "visible": true], ["id": "cpu"]], forKey: SettingsStore.Key.popoverRows)
        let s = SettingsStore(defaults: d)
        #expect(s.units == UnitPreferences(temperature: .celsius, networkRate: .bits))
        #expect(s.popoverLayout.order == [.memory, .cpu, .gpu, .network, .thermals, .power, .disk])
        #expect(s.popoverLayout.hidden == [.memory])
    }

    @Test func atLeastOneRowStaysVisible() {
        let (s, d) = ScreenFixture.settings()
        for c in MonitorModel.Category.allCases { s.setVisible(c, false) }
        #expect(s.visibleRows.count == 1)
        #expect(!s.canHide(s.visibleRows[0]))
        // A stored all-hidden layout is repaired on load.
        d.set(MonitorModel.Category.allCases.map { ["id": $0.rawValue, "visible": false] },
              forKey: SettingsStore.Key.popoverRows)
        #expect(SettingsStore(defaults: d).visibleRows == [.cpu])
    }

    @Test func moveRowsMatchesOnMove() {
        let (s, _) = ScreenFixture.settings()
        s.moveRows(fromOffsets: [0], toOffset: 3)                  // cpu after memory
        #expect(s.popoverLayout.order == [.gpu, .memory, .cpu, .network, .thermals, .power, .disk])
        s.moveRows(fromOffsets: [5, 6], toOffset: 0)
        #expect(s.popoverLayout.order == [.power, .disk, .gpu, .memory, .cpu, .network, .thermals])
    }

    @Test func reenableSensorsClearsKillSwitchAndCrashMarkers() {
        let (s, d) = ScreenFixture.settings()
        s.setDisabled(.coalitions, true)
        d.set(true, forKey: SettingsStore.crashMarkerPrefix + "smc")
        d.set(true, forKey: "unrelated")
        s.reenableSensors()
        #expect(s.disabledSensors.isEmpty)
        #expect(d.object(forKey: SettingsStore.crashMarkerPrefix + "smc") == nil)
        #expect(d.bool(forKey: "unrelated"))
        #expect(SettingsStore(defaults: d).disabledSensors.isEmpty)
    }

    @Test func legacyCommaStringDisabledSensors() {
        let (_, d) = ScreenFixture.settings()
        d.set("soc,smc", forKey: SettingsStore.Key.disabledSensors)
        #expect(SettingsStore(defaults: d).disabledSensors == [.soc, .smc])
    }

    @Test func suitePerDataDirectoryIsStable() {
        let a = SettingsStore.suiteName(for: URL(fileURLWithPath: "/tmp/a/"))
        #expect(a == SettingsStore.suiteName(for: URL(fileURLWithPath: "/tmp/a")))
        #expect(a != SettingsStore.suiteName(for: URL(fileURLWithPath: "/tmp/b")))
        #expect(a.hasPrefix("dev.telltale.Telltale."))
    }
}

@Suite("Shell screen catalog") @MainActor
struct ShellScreenCatalogTests {
    @Test func registersEveryScreen() {
        let ids = ScreenCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        for page in DashboardPage.allCases { #expect(ids.contains(page.rawValue)) }
        for id in ["popover", "popover-alert", "status-icons", "settings"] { #expect(ids.contains(id)) }
        #expect(ScreenCatalog.entry("popover-alert")?.defaultScenario == .thermalFair)
        #expect(ScreenCatalog.entry("overview")?.size == CGSize(width: 1280, height: 860))
    }

    @Test func everyEntryBuildsForEveryScenario() {
        for e in ScreenCatalog.entries {
            for s in MockScenario.allCases { _ = e.make(s) }
        }
    }

    @Test func mockLiveModelIsPresentingAndDeterministic() {
        let m = LiveModel.mock(.calm)
        #expect(m.isPresenting)
        let p = LiveModel.mock(.paused)
        if case .paused = p.phase {} else { Issue.record("paused scenario not paused: \(p.phase)") }
        #expect(p.alert.paused)
    }

    @Test func contextIsSnapshotDeterministic() {
        let ctx = ScreenFixture.context(.calm, page: .cpu)
        #expect(ctx.isSnapshot)
        #expect(ctx.now == MockDataProvider.referenceDate)
        #expect(ctx.navigation.page == .cpu)
        #expect(ctx.settings.units == UnitPreferences())
    }
}
