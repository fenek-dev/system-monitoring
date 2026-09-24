import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

private func row(_ pid: Int32, cid: UInt64?, _ prov: Provenance, cpu: Double? = nil, gpu: Double? = nil,
                 watts: Double? = nil) -> ProcessSample {
    ProcessSample(id: pid < 0 ? .coalitionResidual(cid!) : ProcessID(pid: pid, startTimeUs: 1), app: .system,
                  provenance: prov, coalitionID: cid, cpuPercent: cpu, gpuPercent: gpu, energyWatts: watts)
}

private func coalitions(_ watts: [UInt64: Double?], seconds: Double = 2) -> CoalitionDeltas {
    CoalitionDeltas(byID: watts.mapValues { w in
        CoalitionDelta(cpuNs: 0, energyNJ: w.map { UInt64(($0 * 1e9 * seconds).rounded()) }, seconds: seconds)
    })
}

private let soc = SoCPowerReading(interval: .seconds(1), cpuWatts: 4, gpuWatts: 2)

@Suite struct EnergyAttributorTests {
    @Test func measuredV6WinsInAllVisibleCoalition() {
        // own app: v6 3.3 W while its (all-visible) coalition meter reads 2.6 W → keep 3.3, no residual anywhere
        var e = RulingEnergyAttributor()
        let ps = [row(10, cid: 5, .measured, cpu: 100, watts: 3.3)]
        let w = e.watts(processes: ps, coalitions: coalitions([5: 2.6]), soc: soc, dt: 1)
        #expect(w == [ps[0].id: 3.3])
        #expect(!e.usesSoCShareFallback)
    }

    @Test func singleFilledMemberGetsCoalitionResidual() throws {
        var e = RulingEnergyAttributor()
        let ps = [row(10, cid: 5, .measured, cpu: 20, watts: 0.5), row(418, cid: 5, .coalition, cpu: 50)]
        let w = e.watts(processes: ps, coalitions: coalitions([5: 2.0]), soc: soc, dt: 1)
        #expect(w[ps[0].id] == 0.5)
        #expect(abs(try #require(w[ps[1].id]) - 1.5) < 1e-9)
        #expect(!e.usesSoCShareFallback)
    }

    @Test func syntheticRowGetsResidualAndRestrictedMembersStayNil() throws {
        var e = RulingEnergyAttributor()
        let ps = [row(0, cid: 1, .restricted), row(1, cid: 1, .restricted), row(-1, cid: 1, .coalition, cpu: 30),
                  row(50, cid: 1, .measured, cpu: 1, watts: 0.25)]
        let w = e.watts(processes: ps, coalitions: coalitions([1: 1.0]), soc: soc, dt: 1)
        #expect(abs(try #require(w[.coalitionResidual(1)]) - 0.75) < 1e-9)
        #expect(w[ps[0].id] == nil && w[ps[1].id] == nil)
        #expect(!e.usesSoCShareFallback)                      // restricted rows have no CPU share to fill from
    }

    @Test func residualClampedAtZero() {
        var e = RulingEnergyAttributor()
        let ps = [row(10, cid: 5, .measured, cpu: 20, watts: 3), row(418, cid: 5, .coalition, cpu: 1)]
        #expect(e.watts(processes: ps, coalitions: coalitions([5: 2.0]), soc: soc, dt: 1)[ps[1].id] == 0)
    }

    @Test func coalitionWithoutEnergyLeavesRowForSoCShare() throws {
        var e = RulingEnergyAttributor()
        let ps = [row(10, cid: 5, .measured, cpu: 60, watts: 1), row(418, cid: 5, .coalition, cpu: 40)]
        let w = e.watts(processes: ps, coalitions: coalitions([5: nil]), soc: soc, dt: 1)
        #expect(abs(try #require(w[ps[1].id]) - 4 * 0.4) < 1e-9)   // cpuW × its CPU share
        #expect(e.usesSoCShareFallback)
    }

    @Test func v6UnavailableSkipsCoalitionResidualAndNeverDoubleCounts() {
        var e = RulingEnergyAttributor()
        // no measured row has v6 energy → fallback mode: SoC share for everyone, coalition energy ignored
        let ps = [row(10, cid: 5, .measured, cpu: 100, gpu: 10), row(11, cid: 5, .measured, cpu: 50),
                  row(418, cid: 5, .coalition, cpu: 150, gpu: 30),
                  row(0, cid: 1, .restricted, gpu: 20), row(1, cid: 1, .restricted), row(-1, cid: 1, .coalition, cpu: 100),
                  row(12, cid: nil, .measured, gpu: 40)]
        let w = e.watts(processes: ps, coalitions: coalitions([5: 9.0, 1: 9.0]), soc: soc, dt: 1)
        #expect(e.usesSoCShareFallback)
        let total = w.values.reduce(0, +)
        #expect(total <= 4 + 2 + 1e-9)
        #expect(abs(total - 6) < 1e-9)                        // all CPU and all GPU are covered by rows
        let expected: Double = 4.0 * 150.0 / 400.0 + 2.0 * 30.0 / 100.0
        let got: Double = w[ps[2].id] ?? -1
        #expect(abs(got - expected) < 1e-9)                   // not 9 W of coalition energy
        #expect(w[ps[4].id] == nil)                           // no cpu, no gpu share
    }

    @Test func socShareFillsOnlyNils() {
        var e = RulingEnergyAttributor()
        let ps = [row(10, cid: nil, .measured, cpu: 50, watts: 2), row(11, cid: nil, .measured, cpu: 50)]  // 11: first sight
        let w = e.watts(processes: ps, coalitions: CoalitionDeltas(), soc: soc, dt: 1)
        #expect(w[ps[0].id] == 2)
        #expect(w[ps[1].id] == 2)                             // 4 W × 50 %
        #expect(e.usesSoCShareFallback)
    }

    @Test func noSoCLeavesNils() {
        var e = RulingEnergyAttributor()
        let ps = [row(10, cid: nil, .measured, cpu: 50, watts: 2), row(11, cid: nil, .measured, cpu: 50)]
        let w = e.watts(processes: ps, coalitions: CoalitionDeltas(), soc: nil, dt: 1)
        #expect(w[ps[1].id] == nil)
        #expect(!e.usesSoCShareFallback)
    }

    @Test func flagResetsEachTick() {
        var e = RulingEnergyAttributor()
        let nilRow = [row(11, cid: nil, .measured, cpu: 50)]
        _ = e.watts(processes: nilRow, coalitions: CoalitionDeltas(), soc: soc, dt: 1)
        #expect(e.usesSoCShareFallback)
        _ = e.watts(processes: [row(10, cid: nil, .measured, cpu: 5, watts: 1)], coalitions: CoalitionDeltas(), soc: soc, dt: 1)
        #expect(!e.usesSoCShareFallback)
    }
}
