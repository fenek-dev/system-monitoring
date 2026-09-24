import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

/// `FixtureTrim.trimIdle` (probe `--record --trim-idle`): drops only rows whose counters never change.
@Suite struct FixtureTrimTests {
    static func tick(_ n: UInt64, _ ps: [RawProcess], coalitions: [CoalitionUsage] = []) -> RawTick {
        RawTick(wallTime: Date(timeIntervalSince1970: 1_790_000_000 + Double(n)), uptimeNs: n * sec, mode: .interactive,
                processes: .fresh(ProcessTableReading(processes: ps), capturedNs: n * sec),
                coalitions: .fresh(CoalitionsReading(coalitions: coalitions), capturedNs: n * sec),
                hostCPU: .fresh(HostCPUReading(cores: [CoreTicks(user: n * 60, idle: n * 40)], coreKinds: [.performance]),
                                capturedNs: n * sec))
    }

    @Test func keepsChangingNewbornAndOneTickProcessesDropsIdle() {
        let idle = own(5, cpuNs: 1_000)
        let ticks = [
            Self.tick(1, [idle, own(10, cpuNs: 0)]),
            Self.tick(2, [idle, own(10, cpuNs: sec / 2), own(20, start: 9, cpuNs: sec / 4)]),   // 20: newborn
            Self.tick(3, [idle, own(10, cpuNs: sec), own(30, start: 9, cpuNs: sec / 10)]),      // 30: one tick only
            Self.tick(4, [idle, own(10, cpuNs: 3 * sec / 2), own(40, start: 9, cpuNs: 0, energyNJ: 0, diskR: 0, diskW: 0)]),
        ]
        let r = FixtureTrim.trimIdle(ticks)
        let kept = Set(r.ticks.flatMap { $0.processes.value?.processes.map(\.id.pid) ?? [] })
        #expect(kept == [10, 20, 30])                        // idle 5 and the all-zero newborn 40 dropped
        #expect(r.processes == (kept: 3, total: 5))
    }

    @Test func keepsANewbornWhoseNonZeroCountersNeverChangeAfterwards() {
        // Appears at tick 2 with 0.3 s CPU already accrued (counted in full as a newborn), then stays constant.
        let late = own(50, start: 9, cpuNs: 3 * sec / 10)
        let ticks = [
            Self.tick(1, [own(10, cpuNs: 0)]),
            Self.tick(2, [own(10, cpuNs: sec / 2), late]),
            Self.tick(3, [own(10, cpuNs: sec), late]),
            Self.tick(4, [own(10, cpuNs: 3 * sec / 2), late]),
        ]
        let r = FixtureTrim.trimIdle(ticks)
        #expect(r.ticks[1].processes.value?.processes.contains { $0.id.pid == 50 } == true)
        let v = FixtureTrim.verify(full: ticks, trimmed: r.ticks)
        #expect(v.sumCPU == 0)
    }

    @Test func keepsRestrictedMembersAndLeaderOfChangingCoalitionsAndIsExact() {
        var root = own(418, cpuNs: 0)
        root.restricted = true
        root.cpuTimeNs = nil
        let idleLeader = own(7, cpuNs: 100)
        func coal(_ n: UInt64) -> [CoalitionUsage] {
            [CoalitionUsage(id: 1, leaderPID: 7, memberPIDs: [7, 418], cpuTimeNs: n * sec / 3),         // changes
             CoalitionUsage(id: 2, leaderPID: 8, memberPIDs: [8], cpuTimeNs: 42)]                       // idle
        }
        let ticks = (1...4).map { n in
            Self.tick(UInt64(n), [idleLeader, root, own(8, cpuNs: 5), own(10, cpuNs: UInt64(n) * sec / 5)],
                      coalitions: coal(UInt64(n)))
        }
        let r = FixtureTrim.trimIdle(ticks)
        let kept = Set(r.ticks.flatMap { $0.processes.value?.processes.map(\.id.pid) ?? [] })
        #expect(kept == [7, 418, 10])                        // leader + restricted member kept, idle 8 dropped
        #expect(r.coalitions == (kept: 1, total: 2))
        let v = FixtureTrim.verify(full: ticks, trimmed: r.ticks)
        #expect(v.appCPU == 0 && v.sumCPU == 0 && v.systemCPU == 0 && v.sumWatts == 0)
    }
}
