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

    final class Lookup {
        var table: [Int32: UInt64] = [:]
        var calls: [Int32] = []
        func callAsFunction(_ pid: Int32) -> UInt64? { calls.append(pid); return table[pid] }
    }

    static func e(_ pid: Int32, start: UInt64) -> KinfoEntry {
        KinfoEntry(pid: pid, ppid: 1, uid: 0, comm: "p\(pid)", startTimeUs: start)
    }

    @Test func membershipQueriesOnlyNewProcessIDsAndDropsExited() {
        let lookup = Lookup()
        lookup.table = [1: 10, 2: 10, 3: 20]
        var m = CoalitionMembership()
        m.update([Self.e(1, start: 5), Self.e(2, start: 6), Self.e(3, start: 7)]) { lookup($0) }
        #expect(lookup.calls.sorted() == [1, 2, 3])
        #expect(m.members[10] == [1, 2])
        #expect(m.members[20] == [3])

        lookup.calls = []
        lookup.table[4] = 20
        m.update([Self.e(1, start: 5), Self.e(3, start: 7), Self.e(4, start: 8)]) { lookup($0) }
        #expect(lookup.calls == [4])
        #expect(m.members[10] == [1])
        #expect(m.members[20] == [3, 4])

        // pid 3 reused by a new process in another coalition.
        lookup.calls = []
        lookup.table[3] = 30
        m.update([Self.e(1, start: 5), Self.e(3, start: 99), Self.e(4, start: 8)]) { lookup($0) }
        #expect(lookup.calls == [3])
        #expect(m.members[20] == [4])
        #expect(m.members[30] == [3])
        #expect(m.trackedCount == 3)
    }

    @Test func membershipRetriesPidsWithoutCoalitionInfo() {
        let lookup = Lookup()
        var m = CoalitionMembership()
        m.update([Self.e(1, start: 5)]) { lookup($0) }
        m.update([Self.e(1, start: 5)]) { lookup($0) }
        #expect(lookup.calls == [1, 1])
    }

    @Test func leaderIsEarliestStartedMember() {
        let lookup = Lookup()
        lookup.table = [50: 10, 40: 10, 60: 10]
        var m = CoalitionMembership()
        m.update([Self.e(50, start: 3), Self.e(40, start: 9), Self.e(60, start: 3)]) { lookup($0) }
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
