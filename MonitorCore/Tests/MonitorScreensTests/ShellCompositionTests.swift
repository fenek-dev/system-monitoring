import AppKit
import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import SwiftUI
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
        // a following flag is never consumed as the command
        let o = LaunchOptions.parse(arguments: ["--login-item", "--mock", "runaway"], environment: [:])
        #expect(o.loginItemCommand == "status" && o.mockScenario == .runaway)
        let unknown = LaunchOptions.parse(arguments: ["--login-item", "bogus"], environment: [:])
        #expect(unknown.loginItemCommand == "status")
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

    @Test func reenableSensorsClearsKillSwitchAndCallsCanary() {
        let (s, d) = ScreenFixture.settings()
        s.setDisabled(.coalitions, true)
        d.set(true, forKey: "unrelated")
        var canaryCalls = 0
        s.reenableCrashedSensors = { canaryCalls += 1 }
        s.reenableSensors()
        #expect(s.disabledSensors.isEmpty)
        #expect(canaryCalls == 1)
        #expect(d.bool(forKey: "unrelated"))                    // nothing else in the suite is touched
        #expect(SettingsStore(defaults: d).disabledSensors.isEmpty)
    }

    @Test func overlayDefaults() {
        let (s, _) = ScreenFixture.settings()
        #expect(!s.overlayEnabled)
        #expect(s.overlayCorner == .topRight)
        #expect(s.overlayOpacity == 0.85)
        #expect(s.overlayHotKey == .defaultOverlay)
    }

    @Test func overlayPersistsAcrossInstances() {
        let (s, d) = ScreenFixture.settings()
        s.overlayEnabled = true
        s.overlayCorner = .bottomLeft
        s.overlayOpacity = 0.55
        s.overlayHotKey = HotKeySpec(keyCode: 0, modifiers: 256 | 4096)
        #expect(d.bool(forKey: SettingsStore.Key.overlayEnabled))
        #expect(d.string(forKey: SettingsStore.Key.overlayCorner) == "bottomLeft")
        #expect(d.dictionary(forKey: SettingsStore.Key.overlayHotKey)?["keyCode"] as? Int == 0)
        #expect(d.dictionary(forKey: SettingsStore.Key.overlayHotKey)?["modifiers"] as? Int == 4352)
        let s2 = SettingsStore(defaults: d)
        #expect(s2.overlayEnabled)
        #expect(s2.overlayCorner == .bottomLeft)
        #expect(s2.overlayOpacity == 0.55)
        #expect(s2.overlayHotKey == HotKeySpec(keyCode: 0, modifiers: 4352))
    }

    @Test func overlayGarbageFallsBackToDefaults() {
        let (_, d) = ScreenFixture.settings()
        d.set("sideways", forKey: SettingsStore.Key.overlayCorner)
        d.set("opaque", forKey: SettingsStore.Key.overlayOpacity)
        d.set(["keyCode": 6, "modifiers": 512], forKey: SettingsStore.Key.overlayHotKey)   // shift only → invalid
        let s = SettingsStore(defaults: d)
        #expect(s.overlayCorner == .topRight)
        #expect(s.overlayOpacity == 0.85)
        #expect(s.overlayHotKey == .defaultOverlay)
        for junk: Any in ["⌥Z", ["keyCode": "6"], ["modifiers": 2048], ["keyCode": -1, "modifiers": 2048]] {
            d.set(junk, forKey: SettingsStore.Key.overlayHotKey)
            #expect(SettingsStore(defaults: d).overlayHotKey == .defaultOverlay)
        }
    }

    @Test func overlayOpacityIsClamped() {
        let (s, d) = ScreenFixture.settings()
        d.set(7.0, forKey: SettingsStore.Key.overlayOpacity)
        #expect(SettingsStore(defaults: d).overlayOpacity == 1.0)
        d.set(0.1, forKey: SettingsStore.Key.overlayOpacity)
        #expect(SettingsStore(defaults: d).overlayOpacity == 0.4)
        s.overlayOpacity = 7.0
        #expect(s.overlayOpacity == 1.0)
        #expect(d.double(forKey: SettingsStore.Key.overlayOpacity) == 1.0)
    }

    @Test func legacyCommaStringDisabledSensors() {
        let (_, d) = ScreenFixture.settings()
        d.set("soc,smc", forKey: SettingsStore.Key.disabledSensors)
        #expect(SettingsStore(defaults: d).disabledSensors == [.soc, .smc])
    }

    @Test func inMemoryDefaultsNeverReachThePersistentDomains() {
        let key = "units.temperature"
        let before = UserDefaults.standard.object(forKey: key) as? String
        let (s, d) = ScreenFixture.settings()
        s.units.temperature = .fahrenheit
        s.setVisible(.gpu, false)
        #expect(d.string(forKey: key) == "fahrenheit")
        #expect(UserDefaults.standard.object(forKey: key) as? String == before)   // nothing leaked to .standard
        #expect(SettingsStore(defaults: d).popoverLayout.hidden == [.gpu])
        #expect(ScreenCatalog.snapshotSettings().defaults is InMemoryDefaults)
    }

    @Test func inMemoryDefaultsCoverEveryTypedAPIAndLeaveStandardUntouched() throws {
        let standardBefore = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("tt.") }
        let d = InMemoryDefaults()
        d.register(defaults: ["tt.reg": 7, "tt.int": 1])
        #expect(d.integer(forKey: "tt.reg") == 7 && d.integer(forKey: "tt.int") == 1)
        d.set(42, forKey: "tt.int")
        d.set(2.5, forKey: "tt.double")
        d.set(Float(1.5), forKey: "tt.float")
        d.set(true, forKey: "tt.bool")
        d.set(URL(fileURLWithPath: "/tmp/x"), forKey: "tt.url")
        d.set(["a": 1], forKey: "tt.dict")
        d.set(["x", "y"], forKey: "tt.strings")
        d.set(Data([1, 2]), forKey: "tt.data")
        d.set("12", forKey: "tt.numericString")
        #expect(d.integer(forKey: "tt.int") == 42)                                  // value beats registration
        #expect(d.double(forKey: "tt.double") == 2.5 && d.float(forKey: "tt.float") == 1.5)
        #expect(d.bool(forKey: "tt.bool") && d.integer(forKey: "tt.numericString") == 12)
        #expect(d.url(forKey: "tt.url")?.path == "/tmp/x")
        #expect(d.dictionary(forKey: "tt.dict")?["a"] as? Int == 1)
        #expect(d.stringArray(forKey: "tt.strings") == ["x", "y"] && d.data(forKey: "tt.data") == Data([1, 2]))
        #expect(d.dictionaryRepresentation()["tt.reg"] as? Int == 7)
        d.removeObject(forKey: "tt.int")
        #expect(d.integer(forKey: "tt.int") == 1)                                   // back to the registered value
        // nothing reached the app's standard domain (and a second instance shares nothing)
        for key in ["tt.int", "tt.double", "tt.float", "tt.bool", "tt.url", "tt.dict", "tt.reg"] {
            #expect(UserDefaults.standard.object(forKey: key) == nil, "\(key)")
            #expect(InMemoryDefaults().object(forKey: key) == nil, "\(key)")
        }
        #expect(UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("tt.") } == standardBefore)
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

    /// Yields between builds so this long main-actor loop doesn't starve timing-sensitive suites.
    @Test func everyEntryBuildsForEveryScenario() async {
        for e in ScreenCatalog.entries {
            for s in MockScenario.allCases {
                _ = e.make(s)
                await Task.yield()
            }
        }
    }

    @Test func mockLiveModelIsPresentingAndDeterministic() {
        let m = LiveModel.mock(.calm)
        #expect(m.isPresenting)
        let p = LiveModel.mock(.paused)
        if case .paused = p.phase {} else { Issue.record("paused scenario not paused: \(p.phase)") }
        #expect(p.alert.paused)
    }

    /// DESIGN §3.15 "First launch"/"Collecting": a chart with fewer than 2 samples shows "Collecting…".
    @Test func collectingMockIsBelowTheChartThreshold() {
        let collectingThreshold = 2
        let c = LiveModel.mock(.collecting)
        #expect(c.isPresenting)
        for metric in [HistoryMetric.cpuUsage, .gpuUsage, .memUsed] {
            #expect(c.series(metric).count < collectingThreshold, "\(metric)")
        }
        // every other scenario keeps the full 61-tick history
        #expect(LiveModel.mock(.calm).series(.cpuUsage).count >= collectingThreshold)
    }

    @Test func contextIsSnapshotDeterministic() {
        let ctx = ScreenFixture.context(.calm, page: .cpu)
        #expect(ctx.isSnapshot)
        #expect(ctx.now == MockDataProvider.referenceDate)
        #expect(ctx.navigation.page == .cpu)
        #expect(ctx.settings.units == UnitPreferences())
    }
}

/// Reads `\.historyPersistent` into a box when its body is evaluated.
@MainActor final class EnvProbeBox { var historyPersistent: Bool? }

struct HistoryPersistentProbe: View {
    let box: EnvProbeBox
    @Environment(\.historyPersistent) private var persistent
    var body: some View {
        box.historyPersistent = persistent
        return Color.clear
    }
}

@Suite("Shell environment") @MainActor
struct ShellEnvironmentTests {
    private func read(_ ctx: ShellContext) -> Bool? {
        let box = EnvProbeBox()
        let host = NSHostingView(rootView: HistoryPersistentProbe(box: box).telltaleEnvironment(ctx))
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        host.layoutSubtreeIfNeeded()
        return box.historyPersistent
    }

    @Test func historyPersistentReachesViews() {
        let ctx = ScreenFixture.context(.calm)
        #expect(ctx.historyPersistent)                          // default
        #expect(read(ctx) == true)
        var mem = ctx
        mem.historyPersistent = false                           // store fell back to memory
        #expect(read(mem) == false)
        #expect(ctx.historyPersistent)                          // the copy got its own status
    }

    /// The store opens in the background: a window built before the open resolved still gets the banner.
    @Test func historyStatusResolvedLaterUpdatesABuiltWindow() async {
        let status = HistoryStatus()
        var ctx = ScreenFixture.context(.calm)
        ctx.historyStatus = status
        let box = EnvProbeBox()
        let host = NSHostingView(rootView: HistoryPersistentProbe(box: box).telltaleEnvironment(ctx))
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        host.layoutSubtreeIfNeeded()
        #expect(box.historyPersistent == true)                  // built before the open finished

        let (opened, open) = AsyncStream.makeStream(of: Bool.self)
        let resolving = Task {
            await status.resolve {
                for await persistent in opened { return persistent }
                return true
            }
        }
        await Task.yield()
        #expect(status.persistent)                              // still waiting: MainActor not blocked
        open.yield(false)                                       // store fell back to memory
        await resolving.value
        #expect(!status.persistent)

        let deadline = ContinuousClock.now + .seconds(2)
        while box.historyPersistent != false, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(box.historyPersistent == false)
    }
}
