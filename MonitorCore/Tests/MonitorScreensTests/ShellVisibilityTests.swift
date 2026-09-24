import CoreGraphics
import Observation
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
        #expect(tall.maxY == CGFloat(937))                                 // still 8 below the menu bar
    }

    @Test func popoverPlacementLeftEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let f = PopoverPlacement.frame(anchor: CGRect(x: 30, y: 945, width: 24, height: 37),
                                       content: CGSize(width: 360, height: 478), visibleFrame: visible,
                                       screenFrame: screen)
        #expect(f.minX == CGFloat(8))
    }

    @Test func popoverPlacementSecondaryScreenWithOffsetOrigin() {
        // Screen left of and above the main one: AppKit origin (−1920, 200), menu bar 24 pt, Dock on the left.
        let screen = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let visible = CGRect(x: -1850, y: 200, width: 1850, height: 1056)
        let anchor = CGRect(x: -400, y: 1256, width: 30, height: 24)
        let f = PopoverPlacement.frame(anchor: anchor, content: CGSize(width: 360, height: 478),
                                       visibleFrame: visible, screenFrame: screen)
        #expect(f.midX == anchor.midX)
        #expect(f.maxY == visible.maxY - 8)
        #expect(f.minY == visible.maxY - 8 - 478)
        let right = PopoverPlacement.frame(anchor: CGRect(x: -20, y: 1256, width: 20, height: 24),
                                           content: CGSize(width: 360, height: 478), visibleFrame: visible,
                                           screenFrame: screen)
        #expect(right.maxX == CGFloat(-8))
        let left = PopoverPlacement.frame(anchor: CGRect(x: -1915, y: 1256, width: 20, height: 24),
                                          content: CGSize(width: 360, height: 478), visibleFrame: visible,
                                          screenFrame: screen)
        #expect(left.minX == CGFloat(-1912))
        let capped = PopoverPlacement.frame(anchor: anchor, content: CGSize(width: 360, height: 5000),
                                            visibleFrame: visible, screenFrame: screen)
        #expect(capped.height == visible.height - 40 && capped.minY >= visible.minY)
    }
}

@MainActor @Observable final class Counter {
    var a = 0
    var b = 0
}

@Suite("Shell observation loop") @MainActor
struct ShellObservationLoopTests {
    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    @Test func deliversInitialValueThenChangesAndReArms() async {
        let c = Counter()
        var seen: [Int] = []
        let loop = ObservationLoop({ c.a }) { seen.append($0) }
        #expect(seen == [0])
        c.a = 1
        await settle()
        c.a = 2                                                   // second change: loop must have re-armed
        await settle()
        #expect(seen == [0, 1, 2])
        loop.cancel()
        c.a = 3
        await settle()
        #expect(seen == [0, 1, 2])
    }

    @Test func dedupesEqualValuesAndIgnoresUntrackedProperties() async {
        let c = Counter()
        var seen: [Bool] = []
        let loop = ObservationLoop({ c.a > 5 }) { seen.append($0) }
        c.a = 1                                                   // tracked, value still false → no callback
        await settle()
        c.b = 9                                                   // untracked
        await settle()
        c.a = 7
        await settle()
        c.a = 8                                                   // still true
        await settle()
        #expect(seen == [false, true])
        _ = loop
    }
}
