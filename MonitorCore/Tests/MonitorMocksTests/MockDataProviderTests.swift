import Foundation
import Testing
import MonitorModel
@testable import MonitorMocks

@Suite struct MockDataProviderTests {
    // MARK: - Determinism

    @Test func sameSeedSameFrame() {
        let a = MockDataProvider(scenario: .calm, seed: 7)
        let b = MockDataProvider(scenario: .calm, seed: 7)
        #expect(a.frame(at: 0) == b.frame(at: 0))
        #expect(a.frame(at: 42) == b.frame(at: 42))
    }

    @Test func repeatedCallsAreStable() {
        let p = MockDataProvider(scenario: .thermalFair, seed: 3)
        #expect(p.frame(at: 10) == p.frame(at: 10))
    }

    @Test(arguments: MockScenario.allCases)
    func everyScenarioProducesAFrame(_ scenario: MockScenario) {
        let p = MockDataProvider(scenario: scenario)
        let f = p.frame(at: 5)
        #expect(f.apps.isEmpty == false)
        #expect(f.device.performanceCores == 8)
        #expect(f.device.efficiencyCores == 4)
    }

    // MARK: - `.calm` matches the artboards' character (DESIGN.md §3: CPU ~34%, GPU ~18%, Memory ~15 GB,
    // Network ~12 MB/s down, SoC ~62 °C, package ~18.6 W — within the artboards' own volatility bounds).

    @Test func calmHeadlineNumbersMatchArtboardRanges() {
        let f = MockDataProvider(scenario: .calm).frame(at: 0)
        #expect((0.03...1.0).contains(f.cpu.usage ?? -1))
        #expect((0...1.0).contains(f.gpu.usage ?? -1))
        #expect((12.0...23.0).contains(Double(f.memory.used ?? 0) / 1_073_741_824))
        #expect((44.0...98.0).contains(f.thermals.socAverage ?? -1))
        #expect((4.0...80.0).contains(f.power.packageWatts ?? -1))
    }

    @Test func calmTopConsumerIsXcode() {
        let f = MockDataProvider(scenario: .calm).frame(at: 0)
        let top = f.apps.first
        #expect(top?.identity.displayName == "Xcode")
        #expect((150...280).contains(top?.cpuPercent ?? -1))
        #expect(top?.memory == UInt64(3.82 * 1_073_741_824))
    }

    // MARK: - Alert scenarios

    @Test func thermalFairElevatesThermalsArcWithFinalCutProCulprit() {
        let f = MockDataProvider(scenario: .thermalFair).frame(at: 0)
        #expect(f.alert.level == .elevated)
        #expect(f.alert.arcs[.thermals] == .elevated)
        #expect(f.alert.active.first?.culprit?.displayName == "Final Cut Pro")
        if case .thermalPressure(let p) = f.alert.active.first?.kind { #expect(p == .fair) } else { Issue.record("expected thermalPressure") }
        #expect(f.thermals.pressure == .fair)
    }

    @Test func thermalCriticalElevatesToCritical() {
        let f = MockDataProvider(scenario: .thermalCritical).frame(at: 0)
        #expect(f.alert.level == .critical)
        #expect(f.thermals.pressure == .critical)
    }

    @Test func memoryWarningAndCriticalRaiseMemoryArc() {
        let warning = MockDataProvider(scenario: .memoryWarning).frame(at: 0)
        #expect(warning.alert.arcs[.memory] == .elevated)
        #expect(warning.memory.pressureLevel == .warning)

        let critical = MockDataProvider(scenario: .memoryCritical).frame(at: 0)
        #expect(critical.alert.arcs[.memory] == .critical)
        #expect(critical.memory.pressureLevel == .critical)
    }

    @Test func runawayFlagsXcodeSustainedOverThreshold() {
        let f = MockDataProvider(scenario: .runaway).frame(at: 0)
        #expect(f.alert.arcs[.cpu] == .elevated)
        guard case .runawayApp(let key, let cpuPercent) = f.alert.active.first?.kind else {
            Issue.record("expected runawayApp"); return
        }
        #expect(key.id == "com.apple.dt.Xcode")
        #expect(cpuPercent >= 100)
    }

    @Test func sensorsUnavailableMarksSoCSMCAndNetworkFlows() {
        let f = MockDataProvider(scenario: .sensorsUnavailable).frame(at: 0)
        #expect(f.sensorHealth[.soc]?.reason != nil)
        #expect(f.sensorHealth[.smc]?.reason != nil)
        #expect(f.sensorHealth[.networkFlows]?.reason != nil)
        #expect(f.power.packageWatts == nil)
        #expect(f.thermals.fans.isEmpty)
    }

    @Test func pausedHasNoInterval() {
        let f = MockDataProvider(scenario: .paused).frame(at: 3)
        #expect(f.mode == .paused)
        #expect(f.interval == nil)
        #expect(f.alert.paused)
    }

    @Test func collectingNeverLeavesNilInterval() {
        let p = MockDataProvider(scenario: .collecting)
        #expect(p.frame(at: 0).interval == nil)
        #expect(p.frame(at: 50).interval == nil)
    }

    // MARK: - Restricted / coalition rows

    @Test func restrictedHasManyRestrictedAndCoalitionRows() {
        let f = MockDataProvider(scenario: .restricted).frame(at: 0)
        let restrictedCount = f.processes.count { $0.provenance == .restricted }
        let coalitionCount = f.processes.count { $0.provenance == .coalition }
        let syntheticResidualCount = f.processes.count { $0.id.isSynthetic }
        #expect(restrictedCount >= 300)
        #expect(coalitionCount >= 5)
        #expect(syntheticResidualCount >= 5)
        // Restricted members show "—" (nil) for CPU/energy; their usage lives in the coalition residual.
        #expect(f.processes.allSatisfy { $0.provenance != .restricted || $0.cpuPercent == nil })
        // Coalition rows carry an rss-sourced memory value once the process table is "open".
        #expect(f.processes.contains { $0.provenance == .coalition && $0.memorySource != nil })
    }

    // MARK: - Scenario invariants: sums consistent, top apps sorted, totals match per-app sums + `.other`.

    @Test(arguments: MockScenario.allCases)
    func appsAreSortedByCPUDescending(_ scenario: MockScenario) {
        let f = MockDataProvider(scenario: scenario).frame(at: 0)
        let cpus = f.apps.map { $0.cpuPercent ?? -1 }
        #expect(cpus == cpus.sorted(by: >))
    }

    @Test(arguments: MockScenario.allCases)
    func cpuSumMatchesSystemTotal(_ scenario: MockScenario) {
        let f = MockDataProvider(scenario: scenario).frame(at: 0)
        let totalCoreUnits = (f.cpu.usage ?? 0) * 100 * Double(f.device.performanceCores + f.device.efficiencyCores)
        let appsSum = f.apps.compactMap(\.cpuPercent).reduce(0, +)
        #expect(abs(totalCoreUnits - appsSum) < 0.001)
    }

    @Test(arguments: MockScenario.allCases)
    func memorySumMatchesAppMemoryBudget(_ scenario: MockScenario) {
        let f = MockDataProvider(scenario: scenario).frame(at: 0)
        let appsSum = f.apps.compactMap(\.memory).reduce(UInt64(0), +)
        #expect(appsSum == (f.memory.appMemory ?? 0))
    }

    @Test(arguments: MockScenario.allCases)
    func networkAndDiskSumsMatchSystemTotals(_ scenario: MockScenario) {
        let f = MockDataProvider(scenario: scenario).frame(at: 0)
        let rxSum = f.apps.compactMap(\.netRxBps).reduce(0, +)
        let txSum = f.apps.compactMap(\.netTxBps).reduce(0, +)
        #expect(abs(rxSum - (f.network.rxBps ?? 0)) < 0.001)
        #expect(abs(txSum - (f.network.txBps ?? 0)) < 0.001)

        let readSum = f.apps.compactMap(\.diskReadBps).reduce(0, +)
        let writeSum = f.apps.compactMap(\.diskWriteBps).reduce(0, +)
        #expect(abs(readSum - (f.disk.readBps ?? 0)) < 0.001)
        #expect(abs(writeSum - (f.disk.writeBps ?? 0)) < 0.001)
    }
}
