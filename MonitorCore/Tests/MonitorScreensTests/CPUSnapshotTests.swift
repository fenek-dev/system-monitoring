import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import os
import SwiftUI
import Testing

@Suite("CPU snapshots")
@MainActor
struct CPUSnapshotTests {
    @Test(arguments: [MockScenario.calm, .sensorsUnavailable, .collecting, .restricted])
    func cpu(_ scenario: MockScenario) {
        assertScreen("cpu", scenario: scenario)
    }

    /// Selected user-owned row → inline [Quit][Force Quit] (DESIGN §2.20), as the artboard shows.
    @Test func selectedRow() {
        let live = ScreenFixture.live(.calm)
        let second = CPUConsumersCard.rows(live)[1]
        let view = CPUPage(selection: second.id)
            .frame(width: ScreenSize.pageContent.width, height: ScreenSize.pageContent.height)
            .screenEnvironment(.calm, page: .cpu)
        assertSnapshot(view, size: ScreenSize.pageContent, named: "cpu-selected-calm")
    }

    @Test func statStripBindings() {
        let items = CPUStatStrip.items(ScreenFixture.live(.calm))
        #expect(items.map(\.label) == ["Total", "User", "System", "Idle", "Load average", "Threads"])
        #expect(items[0].detail == "of 12 cores")
        #expect(items[1].value?.contains(".") == true)            // breakdown: 1 decimal
        #expect(items[4].detail == "1 · 5 · 15 min")
        #expect(items[5].detail?.hasPrefix("in ") == true)
    }

    @Test func loadAverageFitsWithTwoDigitLoads() {
        #expect(W5a.loadAverage([27.5, 26.84, 25.1]) == "27.5 · 26.8 · 25.1")
        #expect(W5a.loadAverage([3.21, 2.88, 2.54]) == "3.21 · 2.88 · 2.54")
    }

    @Test func clusterFrequency() {
        var c = ClusterSnapshot(kind: .performance, coreCount: 8, usage: nil, activeResidency: nil, frequencyMHz: 4_120,
                                maxFrequencyMHz: 4_510, watts: nil)
        #expect(CPUClusterCard.frequency(c) == "4.12 GHz of 4.51 GHz")
        c.maxFrequencyMHz = nil
        #expect(CPUClusterCard.frequency(c) == "4.12 GHz")
        c.frequencyMHz = nil
        #expect(CPUClusterCard.frequency(c) == nil)                 // "—" when the catalog lacks the chip
    }

    /// A3: footer tooltips come from the SoC sensor's status; frequency has no tooltip while collecting.
    @Test func clusterFooterReasons() {
        let cluster = ClusterSnapshot(kind: .performance, coreCount: 8)
        let ok = CPUClusterCard.reasons(clusters: [cluster], health: [:])
        #expect(ok.frequency == "Not reported")
        #expect(ok.ioReport == "Not reported by IOReport")
        let down = CPUClusterCard.reasons(clusters: [cluster], health: [.soc: .unavailable("IOReport not available")])
        #expect(down.frequency == "IOReport not available")
        #expect(down.ioReport == "IOReport not available")
        #expect(CPUClusterCard.reasons(clusters: [], health: [:]).frequency == nil)
        // The sensorsUnavailable scenario carries no IOReport cluster fields.
        let live = ScreenFixture.live(.sensorsUnavailable)
        #expect(live.cpu.clusters.allSatisfy { $0.activeResidency == nil && $0.watts == nil && $0.frequencyMHz == nil })
    }

    // MARK: Ranking (A9, B2)

    static let template: ProcessSample = MockDataProvider(scenario: .calm).frame(at: 60).processes[0]

    static func process(_ pid: Int32, cpu: Double?) -> ProcessSample {
        var p = template
        p.id = ProcessID(pid: pid, startTimeUs: 1)
        p.cpuPercent = cpu
        return p
    }

    @Test func consumersSortedBeforeCapNilLast() {
        var many: [ProcessSample] = []
        for i in 0..<80 {
            let cpu: Double? = i % 7 == 0 ? nil : Double(i)
            many.append(Self.process(Int32(100 + i), cpu: cpu))
        }
        let ranked = CPUConsumersCard.rank(many.shuffled())
        #expect(ranked.count == CPUConsumersCard.cap)
        #expect(ranked.first?.cpuPercent == 79)
        #expect(zip(ranked, ranked.dropFirst()).allSatisfy { ($0.cpuPercent ?? -1) >= ($1.cpuPercent ?? -1) })
        let few = [Self.process(1, cpu: nil), Self.process(2, cpu: 5), Self.process(3, cpu: nil), Self.process(4, cpu: 9)]
        #expect(CPUConsumersCard.rank(few).map(\.pid) == [4, 2, 1, 3])   // nil last, stable
    }

    // MARK: Inline actions (A2) and Force Quit (A9)

    @Test func inlineActionGating() {
        let own = ProcessTarget.process(pid: 500, name: "Xcode", path: nil, uid: 501)
        let root = ProcessTarget.process(pid: 1, name: "launchd", path: nil, uid: 0)
        let other = ProcessTarget.process(pid: 700, name: "postgres", path: nil, uid: 502)
        let me = ProcessTarget.process(pid: 42, name: "Telltale", path: nil, uid: 501)
        func state(_ t: ProcessTarget, selected: Bool = true, canControl: Bool, canConfirm: Bool = true)
            -> InlineActionsCell.Mode {
            InlineActionsCell.state(target: t, selected: selected, canControl: canControl, exited: false,
                                    canConfirm: canConfirm, ownPID: 42, ownBundleID: "dev.telltale.Telltale")
        }
        #expect(state(own, canControl: true) == .inline(forceQuit: true, quitsTelltale: false))
        #expect(state(own, selected: false, canControl: true) == .menu)
        #expect(state(root, canControl: false) == .menu)
        #expect(state(other, canControl: false) == .menu)
        #expect(state(me, canControl: true) == .inline(forceQuit: false, quitsTelltale: true))   // never Force Quit self
        #expect(state(own, canControl: true, canConfirm: false) == .inline(forceQuit: false, quitsTelltale: false))
        #expect(InlineActionsCell.state(target: own, selected: true, canControl: true, exited: true) == .none)
    }

    @Test func forceQuitOnlyAfterConfirm() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let actions = ProcessActions(canControl: { _ in true }, forceQuit: { _ in
            calls.withLock { $0 += 1 }
            return .done
        })
        let target = ProcessTarget.process(pid: 500, name: "Xcode", path: nil, uid: 501)
        #expect(await ForceQuitFlow.run(target, confirm: { false }, actions: actions) == .cancelled)
        #expect(calls.withLock { $0 } == 0)
        #expect(await ForceQuitFlow.run(target, confirm: { true }, actions: actions) == .done)
        #expect(calls.withLock { $0 } == 1)
        #expect(ForceQuitFlow.message(target).title == "Force quit “Xcode”?")
        #expect(ActionFeedback.message(.forceQuit, .done, name: "Xcode") == "Xcode was force quit.")
        #expect(ActionFeedback.message(.quit, .notPermitted, name: "launchd") == "Not permitted to quit launchd.")
        #expect(ActionFeedback.message(.quit, .cancelled, name: "x") == nil)
    }

    /// A10 / ICR-13: the synthetic "Exited processes" row has no PID, no actions, italic secondary name.
    @Test func exitedResidualRow() {
        var p = Self.process(-2, cpu: 150)   // ranks second, so the row is visible
        p.provenance = .coalition
        p.name = "Exited processes"
        #expect(p.isExitedResidualRow)
        #expect(InlineActionsCell.state(target: p.target, selected: true, canControl: true,
                                        exited: p.isExitedResidualRow) == .none)
        var measured = Self.process(500, cpu: 12)
        measured.provenance = .measured
        #expect(!measured.isExitedResidualRow)
        let live = LiveModel(device: MockDataProvider(scenario: .calm).device)
        var f = MockDataProvider(scenario: .calm).frame(at: 60)
        f.processes.append(p)
        live.apply(f)
        live.isPresenting = true
        let view = CPUPage(selection: p.id)
            .frame(width: ScreenSize.pageContent.width, height: ScreenSize.pageContent.height)
            .telltaleEnvironment({ var c = ScreenFixture.context(.calm, page: .cpu); c.live = live; return c }())
        assertSnapshot(view, size: ScreenSize.pageContent, named: "cpu-exited-row-calm")
    }
}
