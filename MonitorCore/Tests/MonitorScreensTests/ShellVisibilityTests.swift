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
        #expect(i.visibility.demand == .perCore)                  // ICR-7: CPU page, no inspected app
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

    @Test func inspectedAppOnlyOnVisibleProcessesPage() {       // ICR-10
        let key = AppKey(kind: .app, id: "com.apple.Safari")
        var i = VisibilityInputs()
        i.dashboardOpen = true
        i.inspectedApp = key
        i.page = .overview
        #expect(i.visibility.inspectedApp == nil)
        i.page = .processes
        #expect(i.visibility.inspectedApp == key)
        #expect(i.visibility.demand.contains(.connections))
        i.dashboardMiniaturized = true                          // not visible → no connections
        #expect(i.visibility.inspectedApp == nil && !i.visibility.demand.contains(.connections))
        i.dashboardMiniaturized = false
        i.inspectedApp = nil                                    // inspector collapsed
        #expect(i.visibility.inspectedApp == nil && !i.visibility.demand.contains(.connections))
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
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)          // 37-pt menu bar
        let anchor = CGRect(x: 1000, y: 945, width: 30, height: 37)
        let f = PopoverPlacement.frame(anchor: anchor, content: CGSize(width: 360, height: 478), visibleFrame: visible)
        #expect(f == CGRect(x: 835, y: 945 - 8 - 478, width: 360, height: 478))
        let tall = PopoverPlacement.frame(anchor: anchor, content: CGSize(width: 360, height: 2000), visibleFrame: visible)
        #expect(tall.height == CGFloat(905))
        #expect(tall.maxY == CGFloat(937))                                 // still 8 below the menu bar
    }

    /// CP2 bug: item at x≈1405 on a 1512-pt screen put the panel at x 1225 (maxX 1585, clipped).
    @Test(arguments: [CGFloat(1512), 1800])
    func popoverPlacementRightEdgeOnRealScreenWidths(_ width: CGFloat) {
        let visible = CGRect(x: 0, y: 0, width: width, height: 945)
        for itemX in stride(from: width - 400, through: width - 20, by: 15) {
            let f = PopoverPlacement.frame(anchor: CGRect(x: itemX, y: 945, width: 22, height: 22),
                                           content: CGSize(width: 360, height: 478), visibleFrame: visible)
            #expect(f.maxX <= width - 8 && f.minX >= 8, "item x \(itemX)")
        }
        let cp2 = PopoverPlacement.frame(anchor: CGRect(x: 1394, y: 945, width: 22, height: 22),
                                         content: CGSize(width: 360, height: 478),
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945))
        #expect(cp2.maxX == CGFloat(1504))
    }

    @Test func popoverPlacementUsesActualWidthAndVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)          // Dock on the right: 72 pt
        let f = PopoverPlacement.frame(anchor: CGRect(x: 1420, y: 875, width: 20, height: 25),
                                       content: CGSize(width: 372, height: 478), visibleFrame: visible)
        #expect(f.maxX == CGFloat(1432) && f.width == 372)
        // AppKit grew the panel after placement (origin kept, top above the menu bar): re-clamp.
        let grown = CGRect(x: f.minX, y: f.minY, width: 400, height: 600)
        let c = PopoverPlacement.clamp(grown, visibleFrame: visible)
        #expect(c.maxX == CGFloat(1432) && c.maxY == CGFloat(867))
        // tall content grown by AppKit: height capped (visible − 40), top still 8 below the menu bar
        let tall = PopoverPlacement.clamp(CGRect(x: f.minX, y: -900, width: 372, height: 2000), visibleFrame: visible)
        #expect(tall.height == CGFloat(835) && tall.maxY == CGFloat(867) && tall.minY == CGFloat(32))
        // tiny visible frame (< 108 pt): 100-pt floor; the top rule wins (hangs 8 below the menu bar)
        let tinyVisible = CGRect(x: 0, y: 40, width: 1440, height: 90)
        let tiny = PopoverPlacement.clamp(CGRect(x: 100, y: 0, width: 360, height: 478), visibleFrame: tinyVisible)
        #expect(tiny.height == CGFloat(100) && tiny.maxY == CGFloat(122) && tiny.minY == CGFloat(22))
        // exactly 108 pt: fits, bottom on the visible minY
        let edge = PopoverPlacement.clamp(CGRect(x: 100, y: 0, width: 360, height: 478),
                                          visibleFrame: CGRect(x: 0, y: 40, width: 1440, height: 108))
        #expect(edge.maxY == CGFloat(140) && edge.minY == CGFloat(40))
        // wider than the screen → pinned left
        let huge = PopoverPlacement.frame(anchor: CGRect(x: 100, y: 875, width: 20, height: 25),
                                          content: CGSize(width: 2000, height: 478), visibleFrame: visible)
        #expect(huge.minX == CGFloat(8))
    }

    @Test func popoverPlacementLeftEdge() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let f = PopoverPlacement.frame(anchor: CGRect(x: 30, y: 945, width: 24, height: 37),
                                       content: CGSize(width: 360, height: 478), visibleFrame: visible)
        #expect(f.minX == CGFloat(8))
    }

    @Test func popoverPlacementSecondaryScreenWithOffsetOrigin() {
        // Screen left of and above the main one: AppKit origin (−1920, 200), menu bar 24 pt, Dock on the left (70).
        let visible = CGRect(x: -1850, y: 200, width: 1850, height: 1056)
        let anchor = CGRect(x: -400, y: 1256, width: 30, height: 24)
        let f = PopoverPlacement.frame(anchor: anchor, content: CGSize(width: 360, height: 478), visibleFrame: visible)
        #expect(f.midX == anchor.midX)
        #expect(f.maxY == visible.maxY - 8)
        #expect(f.minY == visible.maxY - 8 - 478)
        let right = PopoverPlacement.frame(anchor: CGRect(x: -20, y: 1256, width: 20, height: 24),
                                           content: CGSize(width: 360, height: 478), visibleFrame: visible)
        #expect(right.maxX == CGFloat(-8))
        let left = PopoverPlacement.frame(anchor: CGRect(x: -1915, y: 1256, width: 20, height: 24),
                                          content: CGSize(width: 360, height: 478), visibleFrame: visible)
        #expect(left.minX == CGFloat(-1842))                              // clear of the Dock
        let capped = PopoverPlacement.frame(anchor: anchor, content: CGSize(width: 360, height: 5000),
                                            visibleFrame: visible)
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
