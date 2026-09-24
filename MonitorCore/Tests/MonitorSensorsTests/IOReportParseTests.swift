import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Parse layer on captured M1 Max deltas (`Fixtures/W6b/ioreport_{idle,load,gpu}.json`, macOS 26.5).
struct IOReportParseTests {
    private let m1Max = try! PStateCatalog.bundled().tables(forModel: "MacBookPro18,4")

    private func reading(_ name: String, tables: PStateTables?) throws -> (SoCPowerReading, IOReportFixture) {
        let f = try W6bFixture.decode(name, as: IOReportFixture.self)
        return (IOReportParse.reading(channels: f.channels, interval: .nanoseconds(f.intervalNs), pstates: tables), f)
    }

    private func state(_ name: String, _ r: Int64) -> IOReportChannelSample.State { .init(name: name, residency: r) }

    @Test func energyUnitsToJoules() {
        #expect(IOReportParse.joules(1500, unit: "mJ") == 1.5)
        #expect(IOReportParse.joules(2_000_000, unit: "uJ") == 2)
        #expect(IOReportParse.joules(3_000_000_000, unit: "nJ") == 3)
        #expect(IOReportParse.joules(1, unit: "W") == nil)
        #expect(IOReportParse.joules(1, unit: nil) == nil)
    }

    @Test func idleFixtureWattsMatchRawCounters() throws {
        let (r, f) = try reading("ioreport_idle.json", tables: m1Max)
        let seconds = Double(f.intervalNs) / 1e9
        let raw = try #require(f.channels.first { $0.name == "CPU Energy" }?.value)
        #expect(abs((r.cpuWatts ?? -1) - Double(raw) / 1e3 / seconds) < 1e-9)
        let gpuRaw = try #require(f.channels.first { $0.name == "GPU Energy" }?.value)   // nJ, preferred over GPU0
        #expect(abs((r.gpuWatts ?? -1) - Double(gpuRaw) / 1e9 / seconds) < 1e-9)
        #expect(r.aneWatts != nil && r.dramWatts != nil)
        #expect(r.clusters.map(\.name) == ["ECPU", "PCPU", "PCPU1"])
        #expect(r.clusters.map(\.kind) == [.efficiency, .performance, .performance])
        for c in r.clusters {
            #expect(c.activeFraction > 0 && c.activeFraction <= 1)
            #expect(c.watts != nil)
            let mhz = try #require(c.frequencyMHz)
            #expect(mhz >= 600 && mhz <= (c.kind == .efficiency ? 2064 : 3228))
        }
        #expect(r.clusters[0].maxFrequencyMHz == 2064)
        #expect(r.clusters[1].maxFrequencyMHz == 3228)
        #expect(r.gpuActiveFraction != nil)
        #expect(r.mediaEngines.map(\.name) == ["Video encoder/scaler"])
    }

    @Test func eightYesFixturePinsPClustersAtMax() throws {
        let (idle, _) = try reading("ioreport_idle.json", tables: m1Max)
        let (load, _) = try reading("ioreport_load.json", tables: m1Max)
        #expect((load.cpuWatts ?? 0) - (idle.cpuWatts ?? 0) >= 4)
        for c in load.clusters where c.kind == .performance {
            #expect(c.activeFraction >= 0.99)
            #expect(abs((c.frequencyMHz ?? 0) - 3228) < 5)
        }
    }

    @Test func gpuFixtureResolvesMHzFromP1toP6() throws {
        let (r, f) = try reading("ioreport_gpu.json", tables: m1Max)
        let gpuph = try #require(f.channels.first { $0.name == "GPUPH" }?.states)
        #expect(gpuph.count == 16)                 // OFF + P1…P15, only P1…P6 used
        #expect((r.gpuActiveFraction ?? 0) > 0.95)
        #expect(abs((r.gpuFrequencyMHz ?? 0) - 1296) < 1)
        #expect(r.gpuMaxFrequencyMHz == 1296)
        #expect((r.gpuWatts ?? 0) > 10)
    }

    @Test func unknownChipLeavesMHzNil() throws {
        let (r, _) = try reading("ioreport_load.json", tables: nil)
        #expect(!r.clusters.isEmpty)
        #expect(r.clusters.allSatisfy { $0.frequencyMHz == nil && $0.maxFrequencyMHz == nil })
        #expect(r.gpuFrequencyMHz == nil && r.gpuMaxFrequencyMHz == nil)
        #expect(r.cpuWatts != nil)
    }

    @Test func residencyTableFit() {
        let table: [Double] = [100, 200]
        // exact fit, weighted by residency
        let a = IOReportParse.residency([state("OFF", 50), state("P1", 25), state("P2", 25)], table: table)
        #expect(a?.active == 0.5 && a?.mhz == 150)
        // extra states without residency still fit
        let b = IOReportParse.residency([state("OFF", 0), state("P1", 0), state("P2", 10), state("P3", 0)], table: table)
        #expect(b?.mhz == 200)
        // residency past the table → nil MHz, activity still reported
        let c = IOReportParse.residency([state("OFF", 0), state("P1", 1), state("P2", 1), state("P3", 1)], table: table)
        #expect(c?.mhz == nil && c?.active == 1)
        // too few states → nil MHz
        #expect(IOReportParse.residency([state("IDLE", 1), state("P1", 1)], table: table)?.mhz == nil)
        // fully idle → active 0, no MHz
        let d = IOReportParse.residency([state("IDLE", 10), state("P1", 0), state("P2", 0)], table: table)
        #expect(d?.active == 0 && d?.mhz == nil)
        // nothing recorded → nil
        #expect(IOReportParse.residency([state("OFF", 0)], table: nil) == nil)
        // INACT/ACT (SoC cluster power states), DOWN
        #expect(IOReportParse.residency([state("INACT", 3), state("ACT", 1)], table: nil)?.active == 0.25)
        #expect(IOReportParse.residency([state("DOWN", 1), state("P1", 1)], table: nil)?.active == 0.5)
    }

    @Test func clusterNamesAndEnergyChannels() {
        #expect(IOReportParse.clusterKind("ECPU") == .efficiency)
        #expect(IOReportParse.clusterKind("PCPU1") == .performance)
        #expect(IOReportParse.clusterKind("ECPM") == nil)
        #expect(IOReportParse.clusterKind("PCPM1") == nil)
        #expect(IOReportParse.clusterKind("GPUPH") == nil)
        #expect(IOReportParse.clusterEnergyNames("ECPU") == ["EACC_CPU", "EACC0_CPU"])
        #expect(IOReportParse.clusterEnergyNames("PCPU") == ["PACC_CPU", "PACC0_CPU"])
        #expect(IOReportParse.clusterEnergyNames("PCPU1") == ["PACC1_CPU"])
    }

    @Test func fallbacksWithoutAggregateChannels() {
        let ch: [IOReportChannelSample] = [
            .init(group: "Energy Model", subgroup: "", name: "GPU0", unit: "mJ", value: 2000),
            .init(group: "Energy Model", subgroup: "", name: "ANE0", unit: "mJ", value: 500),
            .init(group: "Energy Model", subgroup: "", name: "ANE1", unit: "mJ", value: 500),
            .init(group: "Energy Model", subgroup: "", name: "EACC_CPU", unit: "mJ", value: 1000),
            .init(group: "Energy Model", subgroup: "", name: "PACC_CPU", unit: "mJ", value: 3000),
            .init(group: "Energy Model", subgroup: "", name: "DRAM0", unit: "furlongs", value: 3000),
            .init(group: "CPU Stats", subgroup: "CPU Complex Performance States", name: "ECPU",
                  states: [state("IDLE", 1), state("V0P0", 1)]),
            .init(group: "CPU Stats", subgroup: "CPU Complex Performance States", name: "PCPU",
                  states: [state("IDLE", 0), state("V0P0", 1)]),
        ]
        let r = IOReportParse.reading(channels: ch, interval: .seconds(2), pstates: nil)
        #expect(r.gpuWatts == 1)                   // GPU0 when "GPU Energy" is absent
        #expect(r.aneWatts == 0.5)                 // Σ ANE*
        #expect(r.dramWatts == nil)                // unknown unit
        #expect(r.cpuWatts == 2)                   // Σ cluster watts when "CPU Energy" is absent
        #expect(r.clusters.map(\.watts) == [0.5, 1.5])
        #expect(r.mediaEngines.isEmpty)
        #expect(IOReportParse.reading(channels: ch, interval: .zero, pstates: nil).gpuWatts == nil)
    }
}

struct PStateCatalogTests {
    @Test func bundledM1MaxTables() throws {
        let catalog = try PStateCatalog.bundled()
        let t = try #require(catalog.tables(forModel: "MacBookPro18,4"))
        #expect(t.ecpuMHz == [600, 972, 1332, 1704, 2064])
        #expect(t.pcpuMHz.count == 15 && t.pcpuMHz.first == 600 && t.pcpuMHz.last == 3228)
        #expect(t.gpuMHz == [388.8, 486, 648, 777.6, 972, 1296])
        #expect(t.pcpuMHz == t.pcpuMHz.sorted() && t.ecpuMHz == t.ecpuMHz.sorted())
        #expect(catalog.tables(forModel: "Mac13,1") == t)
    }

    @Test func unknownModelIsNil() throws {
        let catalog = try PStateCatalog.bundled()
        #expect(catalog.tables(forModel: "Mac99,9") == nil)
        #expect(catalog.tables(forModel: "") == nil)
        #expect(catalog.models.values.allSatisfy { catalog.chips[$0] != nil })
    }
}
