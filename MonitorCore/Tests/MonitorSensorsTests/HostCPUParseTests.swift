import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct HostCPUParseTests {
    @Test func loadInfoMapsCPUStateIndices() {
        // [user, system, idle, nice] per core, CPU_STATE_* order.
        let raw: [Int32] = [10, 20, 30, 1, 5, 6, 7, 0]
        let ticks = HostCPUParser.coreTicks(raw, cpuCount: 2)
        #expect(ticks == [[10, 20, 30, 1], [5, 6, 7, 0]])
    }

    @Test func loadInfoIgnoresTruncatedTrailingCore() {
        #expect(HostCPUParser.coreTicks([1, 2, 3, 4, 5, 6], cpuCount: 2).count == 1)
    }

    @Test func negativeInt32TicksAreReadAsUnsigned() {
        // natural_t counters above 2^31 come back as negative integer_t.
        #expect(HostCPUParser.coreTicks([-1, 0, 0, 0], cpuCount: 1) == [[UInt32.max, 0, 0, 0]])
    }

    @Test func accumulatorExtendsTo64BitAcrossWrap() {
        var acc = TickAccumulator()
        let first = acc.update([[UInt32.max - 5, 100, 1_000, 0]])
        #expect(first == [CoreTicks(user: UInt64(UInt32.max - 5), system: 100, idle: 1_000, nice: 0)])
        let second = acc.update([[10, 150, 1_000, 0]])      // user wrapped: +16
        #expect(second == [CoreTicks(user: UInt64(UInt32.max) + 11, system: 150, idle: 1_000, nice: 0)])
    }

    @Test func backwardsJumpIsAResetNotAHugeStep() {
        var acc = TickAccumulator()
        _ = acc.update([[1_000, 0, 0, 0]])
        let r = acc.update([[10, 0, 0, 0]])                   // counter reset to 0, then +10
        #expect(r == [CoreTicks(user: 1_010)])
    }

    @Test func accumulatorRebaselinesWhenCoreCountChanges() {
        var acc = TickAccumulator()
        _ = acc.update([[100, 0, 0, 0]])
        let r = acc.update([[5, 0, 0, 0], [7, 0, 0, 0]])
        #expect(r == [CoreTicks(user: 5), CoreTicks(user: 7)])
    }

    // MARK: core kinds

    @Test func clusterTypeData() {
        #expect(CoreKindParser.kind(clusterType: Data("E\0".utf8)) == .efficiency)
        #expect(CoreKindParser.kind(clusterType: Data("P".utf8)) == .performance)
        #expect(CoreKindParser.kind(clusterType: Data("X".utf8)) == nil)
        #expect(CoreKindParser.kind(clusterType: Data()) == nil)
    }

    @Test func kindsFromDeviceTreeOrderedByLogicalID() {
        let entries = [CoreKindParser.Entry(logicalID: 2, kind: .performance),
                       CoreKindParser.Entry(logicalID: 0, kind: .efficiency),
                       CoreKindParser.Entry(logicalID: 1, kind: .efficiency)]
        #expect(CoreKindParser.kinds(deviceTree: entries, cpuCount: 3, performance: 1, efficiency: 2)
                == [.efficiency, .efficiency, .performance])
    }

    @Test func incompleteDeviceTreeFallsBackToPerfLevels() {
        let entries = [CoreKindParser.Entry(logicalID: 0, kind: .efficiency)]
        #expect(CoreKindParser.kinds(deviceTree: entries, cpuCount: 4, performance: 2, efficiency: 2)
                == [.efficiency, .efficiency, .performance, .performance])
    }

    @Test func noPerfLevelsMeansAllPerformance() {
        #expect(CoreKindParser.kinds(deviceTree: [], cpuCount: 3, performance: 0, efficiency: 0)
                == [.performance, .performance, .performance])
    }

    @Test func perfLevelsNotMatchingCountFallBackToAllPerformance() {
        #expect(CoreKindParser.kinds(deviceTree: [], cpuCount: 3, performance: 8, efficiency: 2)
                == [.performance, .performance, .performance])
    }

    /// `ioreg -p IODeviceTree -n cpus` captured on this Mac (M1 Max: cpu0–1 E, cpu2–9 P).
    @Test func capturedDeviceTree() throws {
        let entries = try JSONDecoder().decode([CoreKindParser.Entry].self, from: W6aFixture.data("cpus_devicetree.json"))
        let kinds = CoreKindParser.kinds(deviceTree: entries, cpuCount: 10, performance: 8, efficiency: 2)
        #expect(kinds == [.efficiency, .efficiency] + Array(repeating: .performance, count: 8))
    }
}
