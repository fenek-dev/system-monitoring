import CoreGraphics
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("Shell visibility") @MainActor
struct ShellVisibilityTests {
    @Test func closedUIIsBackground() {
        let v = VisibilityInputs().visibility
        #expect(v == UIVisibility())
        #expect(v.mode == .background && v.demand == .none)
    }

    @Test func popoverAloneIsInteractiveWithoutDemand() {
        var i = VisibilityInputs()
        i.popoverOpen = true
        #expect(i.visibility.mode == .interactive)
        #expect(i.visibility.demand == .none)
    }

    @Test func visibleDashboardCarriesPageDemand() {
        var i = VisibilityInputs()
        i.dashboardOpen = true
        i.page = .cpu
        #expect(i.visibility == UIVisibility(dashboardVisible: true, page: .cpu))
        #expect(i.visibility.demand == [.perCore, .processTable])
    }

    @Test func occludedOrMiniaturizedDashboardIsBackground() {
        var i = VisibilityInputs()
        i.dashboardOpen = true
        i.page = .thermals
        i.dashboardOccluded = true
        #expect(i.visibility.mode == .background && i.visibility.page == nil)
        i.dashboardOccluded = false
        i.dashboardMiniaturized = true
        #expect(i.visibility.mode == .background)
    }

    @Test func inspectedAppOnlyOnProcessesWithAppSelection() {
        let key = AppKey(kind: .app, id: "com.apple.Safari")
        var i = VisibilityInputs()
        i.dashboardOpen = true
        i.selection = .app(key)
        i.page = .overview
        #expect(i.visibility.inspectedApp == nil)
        i.page = .processes
        #expect(i.visibility.inspectedApp == key)
        #expect(i.visibility.demand.contains(.connections))
        i.selection = .process(ProcessID(pid: 1, startTimeUs: 0))
        #expect(i.visibility.inspectedApp == nil)
    }

    @Test func trackerEmitsOnlyDistinctValues() {
        var seen: [UIVisibility] = []
        let t = VisibilityTracker { seen.append($0) }
        t.update { $0.page = .gpu }                         // dashboard closed: no change
        t.update { $0.popoverOpen = true }
        t.update { $0.popoverOpen = true }
        t.update { $0.dashboardOpen = true }
        t.update { $0.dashboardOccluded = true }
        t.update { $0.popoverOpen = false }
        #expect(seen == [
            UIVisibility(popoverOpen: true),
            UIVisibility(popoverOpen: true, dashboardVisible: true, page: .gpu),
            UIVisibility(popoverOpen: true),
            UIVisibility(),
        ])
    }

    @Test func popoverPlacementCentersAndClamps() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)          // 37-pt menu bar
        let anchor = CGRect(x: 1000, y: 945, width: 30, height: 37)
        let f = PopoverPlacement.frame(anchor: anchor, content: CGSize(width: 360, height: 478),
                                       visibleFrame: visible, screenFrame: screen)
        #expect(f == CGRect(x: 835, y: 945 - 8 - 478, width: 360, height: 478))
        let right = PopoverPlacement.frame(anchor: CGRect(x: 1490, y: 945, width: 20, height: 37),
                                           content: CGSize(width: 360, height: 478), visibleFrame: visible,
                                           screenFrame: screen)
        #expect(right.maxX == CGFloat(1504))
        let tall = PopoverPlacement.frame(anchor: anchor, content: CGSize(width: 360, height: 2000),
                                          visibleFrame: visible, screenFrame: screen)
        #expect(tall.height == CGFloat(905))
    }
}
