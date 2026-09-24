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

    /// `referenceDate` must be "24 Sep 2026 14:32 Europe/London" as a fixed instant, not
    /// `Calendar.current`-dependent — the snapshot harness pins Europe/London (ARCHITECTURE §8), so a
    /// machine running with a different `TZ` must compute the exact same `Date`. `referenceDate` is a
    /// `static let` (computed once and cached for the process), so re-running this test after changing
    /// `TZ`/`setenv` wouldn't re-trigger the computation — the robust check (equivalent to running this
    /// suite under `TZ=UTC` and `TZ=Asia/Tashkent` and diffing) is comparing against an instant built
    /// independently, in UTC, with no dependency on the process's local timezone.
    @Test func referenceDateIsTZIndependent() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 24 Sep 2026 falls in British Summer Time (UTC+1), so 14:32 London == 13:32 UTC.
        let expectedUTC = utc.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 13, minute: 32))!
        #expect(MockDataProvider.referenceDate == expectedUTC)
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

    /// Golden values for `.calm` tick 0, precomputed by replaying the artboards' own LCG (seed 11/23/37/
    /// 41/43/53/59, `DemoSpec.calm`) — pins the exact numbers, not just their range, so a change to the
    /// generator, its parameters, or the demo app roster shows up here instead of only in a snapshot diff.
    /// GPU/SoC-temp/package-watts read the raw generator output; CPU/memory are additionally grown to
    /// cover the named apps' own totals (`MockDataProvider.NamedTotals`), so their goldens reflect that.
    @Test func calmGoldenValuesAtTickZero() {
        let f = MockDataProvider(scenario: .calm).frame(at: 0)
        let tolerancePercent = 0.05

        #expect(abs((f.cpu.usage ?? -1) * 100 - 30.1993308) < tolerancePercent)
        #expect(abs((f.gpu.usage ?? -1) * 100 - 23.0369629) < tolerancePercent)
        #expect(abs(Double(f.memory.used ?? 0) - 16_392_742_391) < 1_000)
        #expect(abs((f.network.rxBps ?? -1) - 10_974_977.15) < 100)
        #expect(abs((f.network.txBps ?? -1) - 1_214_806.58) < 100)
        #expect(abs((f.thermals.socAverage ?? -1) - 63.3904389) < tolerancePercent)
        #expect(abs((f.power.packageWatts ?? -1) - 18.1363193) < tolerancePercent)
    }

    /// Regression: `memory.used.map(Double.init)`-style optional-map on a `UInt64?` can silently resolve
    /// to `Double(bitPattern:)` (bit-reinterpretation) instead of the numeric conversion, producing a
    /// denormal ~8e-314 instead of a byte count in the billions. `makeMetrics` must use `.map { Double($0) }`.
    @Test func calmMemoryMetricsAreInByteRangeNotDenormal() {
        let f = MockDataProvider(scenario: .calm).frame(at: 0)
        let byteScale = 1.0e8...3.0e10   // ~0.1 GB … ~28 GB, comfortably inside the 24 GB device's range
        #expect(byteScale.contains(f.metrics[.memUsed] ?? -1))
        #expect(byteScale.contains(f.metrics[.memApp] ?? -1))
        #expect(byteScale.contains(f.metrics[.memWired] ?? -1))
        #expect(byteScale.contains(f.metrics[.memCompressed] ?? -1))
        #expect((1.0e7...5.0e9).contains(f.metrics[.swapUsed] ?? -1))   // ~10 MB … ~5 GB swap
    }

    @Test func calmTopConsumerIsXcode() {
        let f = MockDataProvider(scenario: .calm).frame(at: 0)
        let top = f.apps.first
        #expect(top?.identity.displayName == "Xcode")
        // Xcode's own per-app jitter series (seed 1101, base 212.4 — DESIGN §3.1/§3.4/§3.5) at tick 0.
        #expect(abs((top?.cpuPercent ?? -1) - 214.8058021) < 0.05)
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

    /// DESIGN §3.15 "First launch": the very first sample can't have anything that needs a delta between
    /// two samples yet (CPU%, GPU%, network/disk rates, per-app rates) — only instantaneous reads
    /// (memory levels, temperatures) are available. Regression for the "rendered byte-identical to .calm"
    /// bug: the scenario changed `interval` but left every other field's real numbers in place.
    @Test func collectingHasNoRateDerivedFieldsButKeepsInstantaneousOnes() {
        let f = MockDataProvider(scenario: .collecting).frame(at: 0)

        #expect(f.cpu.usage == nil)
        #expect(f.cpu.user == nil)
        #expect(f.cpu.cores.isEmpty)
        #expect(f.gpu.usage == nil)
        #expect(f.network.rxBps == nil)
        #expect(f.network.txBps == nil)
        #expect(f.disk.readBps == nil)
        #expect(f.disk.writeBps == nil)
        #expect(f.apps.allSatisfy { $0.cpuPercent == nil && $0.netRxBps == nil && $0.energyWatts == nil })
        #expect(f.processes.allSatisfy { $0.cpuPercent == nil && $0.diskReadBps == nil })
        #expect(f.connections.isEmpty)

        // Instantaneous reads (no delta needed) stay real.
        #expect(f.memory.used != nil)
        #expect(f.thermals.socAverage != nil)
        #expect(f.apps.allSatisfy { $0.memory != nil })
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
        // `.sensorsUnavailable` deliberately hides per-app/process network (it comes only from
        // `networkFlows`) while the interface-level total stays up, so the two sides don't reconcile —
        // that asymmetry is the point, not a bug.
        if scenario != .sensorsUnavailable {
            let rxSum = f.apps.compactMap(\.netRxBps).reduce(0, +)
            let txSum = f.apps.compactMap(\.netTxBps).reduce(0, +)
            #expect(abs(rxSum - (f.network.rxBps ?? 0)) < 0.001)
            #expect(abs(txSum - (f.network.txBps ?? 0)) < 0.001)
        }

        let readSum = f.apps.compactMap(\.diskReadBps).reduce(0, +)
        let writeSum = f.apps.compactMap(\.diskWriteBps).reduce(0, +)
        #expect(abs(readSum - (f.disk.readBps ?? 0)) < 0.001)
        #expect(abs(writeSum - (f.disk.writeBps ?? 0)) < 0.001)
    }
}
