import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("Shell navigation") @MainActor
struct ShellNavigationTests {
    @Test func defaults() {
        let n = NavigationModel()
        #expect(n.page == .overview && n.range == .live && n.historyRange == .day)
        #expect(n.processesMode == .apps && n.selection == nil)
    }

    @Test func openKeepsPageForNil() {
        let n = NavigationModel()
        n.open(.thermals)
        #expect(n.page == .thermals)
        n.open(nil)
        #expect(n.page == .thermals)
    }

    @Test func inspectSelectsAppOnProcesses() {
        let n = NavigationModel()
        n.processesMode = .processes
        let key = AppKey(kind: .app, id: "com.apple.dt.Xcode")
        n.inspect(key)
        #expect(n.page == .processes && n.processesMode == .apps && n.selection == .app(key))
        var i = VisibilityInputs()
        i.dashboardOpen = true
        i.page = n.page
        i.selection = n.selection
        #expect(i.visibility.inspectedApp == key)
    }

    @Test func currentRangeFollowsPage() {
        let n = NavigationModel()
        n.currentRange = .hour
        #expect(n.range == .hour && n.historyRange == .day)
        n.page = .history
        #expect(n.currentRange == .day)
        n.currentRange = .week
        #expect(n.historyRange == .week && n.range == .hour)
    }

    @Test func headerSubtitles() {
        let live = LiveModel.mock(.calm)
        let n = NavigationModel()
        #expect(PageHeader.defaultSubtitle(page: .overview, live: live, nav: n) == "Sampling every second · all values live")
        n.range = .day
        #expect(PageHeader.defaultSubtitle(page: .overview, live: live, nav: n) == "Showing last 24 hours")
        #expect(PageHeader.defaultSubtitle(page: .thermals, live: live, nav: n) == "SoC sensors, fans and macOS thermal pressure")
        #expect(PageHeader.defaultSubtitle(page: .history, live: live, nav: n)
            == "Stored locally · 5-minute resolution for 24 hours · kept for 30 days")
        let paused = LiveModel.mock(.paused)
        #expect(PageHeader.defaultSubtitle(page: .overview, live: paused, nav: n) == "Sampling paused")
    }

    @Test func deviceFooterLines() {
        var d = DeviceInfo.placeholder
        d.modelName = "MacBook Pro 14″"
        d.chipName = "Apple M4 Pro"
        d.performanceCores = 8
        d.efficiencyCores = 4
        d.gpuCores = 16
        d.memoryBytes = 24 * 1_073_741_824
        d.bootTime = Date(timeIntervalSince1970: 1_000_000)
        let now = d.bootTime.addingTimeInterval(4 * 86_400 + 7 * 3_600 + 120)
        let l = DeviceHeader.lines(d, now: now)
        #expect(l.model == "MacBook Pro 14″")
        #expect(l.chip == "M4 Pro · 8P + 4E CPU · 16-core GPU")
        #expect(l.memory == "24 GB unified memory · up 4 d 7 h")
    }
}
