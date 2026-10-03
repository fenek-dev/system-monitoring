import Foundation
import Testing
@testable import MonitorModel

@Suite struct UIVisibilityTests {
    /// ICR-7: `.processTable` only where a table shows a per-process memory column (overview, memory, processes).
    static let pageDemand: [(DashboardPage, SamplingDemand)] = [
        (.overview, [.processTable]),
        (.cpu, [.perCore]),
        (.gpu, []),
        (.memory, [.processTable]),
        (.network, [.wifi]),
        (.thermals, [.rawTemperatures]),
        (.power, [.sleepAssertions]),
        (.disk, [.smart, .volumes]),
        (.storage, []),
        (.processes, [.processTable]),
        (.history, []),
    ]

    @Test func tableCoversEveryPage() {
        #expect(Set(Self.pageDemand.map(\.0)) == Set(DashboardPage.allCases))
    }

    @Test(arguments: pageDemand)
    func visiblePageDemand(_ page: DashboardPage, _ expected: SamplingDemand) {
        let v = UIVisibility(popoverOpen: false, dashboardVisible: true, page: page)
        #expect(v.demand == expected)
        #expect(v.mode == .interactive)
    }

    @Test(arguments: pageDemand)
    func inspectedAppAddsConnectionsAndProcessTable(_ page: DashboardPage, _ expected: SamplingDemand) {
        let v = UIVisibility(dashboardVisible: true, page: page, inspectedApp: AppKey(kind: .app, id: "com.example"))
        #expect(v.demand == expected.union([.connections, .processTable]))
    }

    @Test func hiddenDashboardAddsNothing() {
        let v = UIVisibility(popoverOpen: false, dashboardVisible: false, page: .cpu,
                             inspectedApp: AppKey(kind: .app, id: "com.example"))
        #expect(v.demand == .none)
        #expect(v.mode == .background)
    }

    @Test func popoverOnlyIsInteractiveWithoutDemand() {
        let v = UIVisibility(popoverOpen: true, dashboardVisible: false, page: nil)
        #expect(v.demand == .none)
        #expect(v.mode == .interactive)
    }

    @Test func overlayModeResolution() {
        #expect(UIVisibility(overlayVisible: true).mode == .overlay)
        #expect(UIVisibility(popoverOpen: true, overlayVisible: true).mode == .interactive)
        #expect(UIVisibility(dashboardVisible: true, overlayVisible: true).mode == .interactive)
        #expect(UIVisibility().mode == .background)
        #expect(UIVisibility(overlayVisible: true).demand == .none)
        #expect(SamplingMode.overlay.interval == .seconds(1))
    }

    @Test func nothingVisibleIsBackground() {
        let v = UIVisibility()
        #expect(v.demand == .none)
        #expect(v.mode == .background)
        #expect(v.mode.interval == .seconds(5))
    }
}
