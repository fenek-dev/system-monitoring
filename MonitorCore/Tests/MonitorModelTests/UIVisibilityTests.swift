import Foundation
import Testing
@testable import MonitorModel

@Suite struct UIVisibilityTests {
    static let pageDemand: [(DashboardPage, SamplingDemand)] = [
        (.overview, [.processTable]),
        (.cpu, [.perCore, .processTable]),
        (.gpu, [.processTable]),
        (.memory, [.processTable]),
        (.network, [.wifi, .processTable]),
        (.thermals, [.rawTemperatures]),
        (.power, [.processTable, .sleepAssertions]),
        (.disk, [.processTable, .smart, .volumes]),
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
    func inspectedAppAddsConnections(_ page: DashboardPage, _ expected: SamplingDemand) {
        let v = UIVisibility(dashboardVisible: true, page: page, inspectedApp: AppKey(kind: .app, id: "com.example"))
        #expect(v.demand == expected.union(.connections))
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

    @Test func nothingVisibleIsBackground() {
        let v = UIVisibility()
        #expect(v.demand == .none)
        #expect(v.mode == .background)
        #expect(v.mode.interval == .seconds(5))
    }
}
