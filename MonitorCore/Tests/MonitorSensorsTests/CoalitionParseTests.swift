import CPrivate
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct CoalitionParseTests {
    static let size = CoalitionLayout.structSize
    static let tb = MachTimebase(numer: 125, denom: 3)

    /// A buffer as the kernel would leave it: sentinel-filled, then `written` bytes of little-endian words.
    static func buffer(words: [UInt64], written: Int) -> [UInt8] {
        var b = [UInt8](repeating: CoalitionLayout.sentinel, count: size + CoalitionLayout.slack)
        var bytes: [UInt8] = []
        for w in words { withUnsafeBytes(of: w.littleEndian) { bytes.append(contentsOf: $0) } }
        for i in 0..<min(written, bytes.count) { b[i] = bytes[i] }
        return b
    }

    static let goodWords: [UInt64] = (0..<45).map { i in i == 3 ? 24_000_000 : UInt64(i) }

    @Test func structSizeMatchesFindings() {
        #expect(CoalitionLayout.structSize == 360)
    }

    @Test func layoutValidWhenKernelFillsExactlyOurSize() {
        #expect(CoalitionLayout.validate(Self.buffer(words: Self.goodWords, written: Self.size)) == .ok)
    }

    @Test func layoutInvalidWhenKernelWritesPastOurSize() {
        var b = Self.buffer(words: Self.goodWords, written: Self.size)
        b[Self.size + 3] = 0
        #expect(CoalitionLayout.validate(b) == .kernelOverran)
    }

    @Test func layoutInvalidWhenKernelStructIsShorter() {
        // Kernel copied only 44 words: our last field is still sentinel.
        #expect(CoalitionLayout.validate(Self.buffer(words: Self.goodWords, written: Self.size - 8)) == .kernelShorter)
    }

    @Test func layoutInvalidWhenCPUTimeIsZero() {
        var words = Self.goodWords
        words[3] = 0
        #expect(CoalitionLayout.validate(Self.buffer(words: words, written: Self.size)) == .noCPUTime)
    }

    @Test func layoutInvalidOnWrongBufferLength() {
        #expect(CoalitionLayout.validate([UInt8](repeating: 0, count: 10)) == .badBuffer)
    }

    @Test func usageMapsVerifiedWords() {
        var words = [UInt64](repeating: 0, count: 45)
        words[3] = 24_000_000          // 1 s of mach ticks
        words[6] = 4096
        words[7] = 8192
        words[8] = 777                 // gpu_time: unknown unit, raw only
        words[11] = 3_430_000_000      // energy nJ
        let cru = CoalitionLayout.decode(Self.buffer(words: words, written: Self.size))
        let u = CoalitionParser.usage(id: 42, cru: cru, leaderPID: 7, members: [7, 9], timebase: Self.tb)
        #expect(u == CoalitionUsage(id: 42, leaderPID: 7, memberPIDs: [7, 9], cpuTimeNs: 1_000_000_000,
                                    energyNJ: 3_430_000_000, gpuTimeRaw: 777, diskReadBytes: 4096, diskWriteBytes: 8192))
    }

    @Test func listKeepsResourceCoalitionsOnly() {
        var entries = [
            procinfo_coalinfo(coalition_id: 1, coalition_type: UInt32(COALITION_TYPE_RESOURCE), coalition_tasks: 2),
            procinfo_coalinfo(coalition_id: 2, coalition_type: UInt32(COALITION_TYPE_JETSAM), coalition_tasks: 2),
            procinfo_coalinfo(coalition_id: 3, coalition_type: UInt32(COALITION_TYPE_RESOURCE), coalition_tasks: 0),
        ]
        let ids = entries.withUnsafeMutableBytes { raw in
            CoalitionParser.resourceIDs(UnsafeRawBufferPointer(rebasing: raw[0..<(3 * MemoryLayout<procinfo_coalinfo>.stride)]))
        }
        #expect(ids == [1, 3])
    }

    // MARK: membership

    /// pid → (coalition, start µs); a missing pid fails the lookup (e.g. a zombie).
    final class Lookup {
        var table: [Int32: (UInt64, UInt64)] = [:]
        var calls: [Int32] = []
        func callAsFunction(_ pid: Int32) -> CoalitionMembership.Info? {
            calls.append(pid)
            return table[pid].map { .init(coalition: $0.0, startTimeUs: $0.1) }
        }
    }

    @Test func membershipQueriesOnlyNewPidsAndDropsExited() {
        let lookup = Lookup()
        lookup.table = [1: (10, 5), 2: (10, 6), 3: (20, 7)]
        var m = CoalitionMembership()
        m.update(pids: [3, 2, 1]) { lookup($0) }
        #expect(lookup.calls.sorted() == [1, 2, 3])
        #expect(m.members[10] == [1, 2])
        #expect(m.members[20] == [3])

        lookup.calls = []
        lookup.table[4] = (20, 8)
        m.update(pids: [1, 3, 4]) { lookup($0) }
        #expect(lookup.calls == [4])
        #expect(m.members[10] == [1])
        #expect(m.members[20] == [3, 4])
        #expect(m.trackedCount == 3)
    }

    /// Review fix: an exit and a failing lookup in the same tick must still prune the exited pid.
    @Test func exitAndFailedLookupInSameTickPrunes() {
        let lookup = Lookup()
        lookup.table = [1: (10, 1), 2: (10, 2)]
        var m = CoalitionMembership()
        m.update(pids: [1, 2]) { lookup($0) }
        #expect(m.leader(of: 10) == 1)
        // pid 1 exits; pid 3 appears but its lookup fails. Tracked count stays equal to the live count.
        m.update(pids: [2, 3]) { lookup($0) }
        #expect(m.members[10] == [2])
        #expect(m.leader(of: 10) == 2)
        #expect(m.trackedCount == 1)
    }

    @Test func membershipRetriesPidsWithoutCoalitionInfo() {
        let lookup = Lookup()
        var m = CoalitionMembership()
        m.update(pids: [1]) { lookup($0) }
        m.update(pids: [1]) { lookup($0) }
        #expect(lookup.calls == [1, 1])
        lookup.table[1] = (10, 1)
        m.update(pids: [1]) { lookup($0) }
        #expect(m.members[10] == [1])
    }

    @Test func unchangedPidSetDoesNotRebuild() {
        let lookup = Lookup()
        lookup.table = [1: (10, 1), 2: (10, 2)]
        var m = CoalitionMembership()
        m.update(pids: [1, 2]) { lookup($0) }
        let rebuilds = m.rebuilds
        m.update(pids: [2, 1]) { lookup($0) }
        #expect(m.rebuilds == rebuilds)
        #expect(lookup.calls.count == 2)
    }

    @Test func leaderIsEarliestStartedMember() {
        let lookup = Lookup()
        lookup.table = [50: (10, 3), 40: (10, 9), 60: (10, 3)]
        var m = CoalitionMembership()
        m.update(pids: [60, 50, 40]) { lookup($0) }
        #expect(m.leader(of: 10) == 50)   // tie on start time → lower pid
        #expect(m.leader(of: 99) == nil)
    }

    // MARK: captured dump

    /// Own coalition captured on this Mac (`TELLTALE_W6A_CAPTURE=1`): 360 + 64 bytes after a sentinel-filled call.
    @Test func capturedDumpPassesLayoutCheckAndDecodes() throws {
        let bytes = [UInt8](try W6aFixture.data("coalition_usage.bin"))
        #expect(CoalitionLayout.validate(bytes) == .ok)
        let cru = CoalitionLayout.decode(bytes)
        let u = CoalitionParser.usage(id: 1, cru: cru, leaderPID: nil, members: [], timebase: Self.tb)
        #expect(u.cpuTimeNs > 0)
        #expect((u.energyNJ ?? 0) > 0)
        #expect(cru.tasks_started >= cru.tasks_exited)
    }
}
