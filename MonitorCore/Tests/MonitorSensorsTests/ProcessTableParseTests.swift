import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct ProcessTableParseTests {
    // MARK: mach time

    @Test func machTicksConvertWithAppleSiliconTimebase() {
        let tb = MachTimebase(numer: 125, denom: 3)
        #expect(tb.nanoseconds(24_000_000) == 1_000_000_000)   // 24 MHz tick → 1 s
        #expect(tb.nanoseconds(0) == 0)
        #expect(tb.nanoseconds(3) == 125)
    }

    @Test func machTicksSaturateInsteadOfTrapping() {
        let tb = MachTimebase(numer: 125, denom: 3)
        #expect(tb.nanoseconds(.max) == .max)
        #expect(MachTimebase(numer: 1, denom: 1).nanoseconds(.max) == .max)
    }

    @Test func zeroTimebaseFieldsFallBackToIdentity() {
        #expect(MachTimebase(numer: 0, denom: 0).nanoseconds(42) == 42)
        #expect(MachTimebase(numer: 5, denom: 0).nanoseconds(42) == 42)
    }

    @Test func counterDeltaIsGuarded() {
        #expect(w6aCounterDelta(10, 4) == 6)
        #expect(w6aCounterDelta(4, 10) == nil)
        #expect(w6aCounterDelta(7, 7) == 0)
    }

    // MARK: kinfo_proc

    static func makeKinfo(pid: Int32, ppid: Int32, uid: UInt32, comm: [UInt8], sec: Int, usec: Int32) -> kinfo_proc {
        var kp = kinfo_proc()
        kp.kp_proc.p_pid = pid
        kp.kp_eproc.e_ppid = ppid
        kp.kp_eproc.e_ucred.cr_uid = uid
        kp.kp_proc.p_un.__p_starttime = timeval(tv_sec: sec, tv_usec: usec)
        withUnsafeMutableBytes(of: &kp.kp_proc.p_comm) { raw in
            for i in 0..<raw.count { raw[i] = i < comm.count ? comm[i] : 0 }
        }
        return kp
    }

    @Test func kinfoEntryReadsListFields() {
        let kp = Self.makeKinfo(pid: 418, ppid: 1, uid: 88, comm: Array("WindowServer".utf8), sec: 1_788_849_600, usec: 123_456)
        let e = KinfoProcParser.entry(kp)
        #expect(e == KinfoEntry(pid: 418, ppid: 1, uid: 88, comm: "WindowServer", startTimeUs: 1_788_849_600_123_456))
        #expect(e.id == ProcessID(pid: 418, startTimeUs: 1_788_849_600_123_456))
    }

    @Test func kinfoCommWithoutTerminatorIsBoundedTo16Chars() {
        let kp = Self.makeKinfo(pid: 5, ppid: 1, uid: 501, comm: Array(repeating: UInt8(ascii: "x"), count: 17), sec: 1, usec: 0)
        #expect(KinfoProcParser.entry(kp).comm == String(repeating: "x", count: 16))
    }

    @Test func kinfoNegativeStartTimeClampsToZero() {
        let kp = Self.makeKinfo(pid: 5, ppid: 1, uid: 501, comm: Array("a".utf8), sec: -1, usec: -5)
        #expect(KinfoProcParser.entry(kp).startTimeUs == 0)
    }

    @Test func kinfoBufferParsesWholeEntriesOnly() {
        var procs = [
            Self.makeKinfo(pid: 0, ppid: 0, uid: 0, comm: Array("kernel_task".utf8), sec: 10, usec: 0),
            Self.makeKinfo(pid: 1, ppid: 0, uid: 0, comm: Array("launchd".utf8), sec: 11, usec: 0),
            Self.makeKinfo(pid: 99, ppid: 1, uid: 501, comm: Array("zsh".utf8), sec: 12, usec: 0),
        ]
        let stride = MemoryLayout<kinfo_proc>.stride
        let entries = procs.withUnsafeMutableBytes { raw in
            KinfoProcParser.entries(UnsafeRawBufferPointer(rebasing: raw[0..<(2 * stride + 10)]))
        }
        #expect(entries.map(\.pid) == [0, 1])
        #expect(entries.map(\.comm) == ["kernel_task", "launchd"])
    }

    /// Captured on this Mac (`TELLTALE_W6A_CAPTURE=1` smoke test): raw kinfo_proc bytes for launchd, the
    /// test runner's parent and the test runner, with `ps -o pid=,ppid=,uid=,comm=` values recorded next to them.
    @Test func capturedKinfoFixtureMatchesPs() throws {
        let bytes = try W6aFixture.data("kinfo_proc.bin")
        let expected = try JSONDecoder().decode([KinfoEntry].self, from: W6aFixture.data("kinfo_proc.expected.json"))
        let entries = bytes.withUnsafeBytes { KinfoProcParser.entries($0) }
        #expect(entries.count == expected.count)
        for (got, want) in zip(entries, expected) {
            #expect(got.pid == want.pid)
            #expect(got.ppid == want.ppid)
            #expect(got.uid == want.uid)
            #expect(got.comm == want.comm)
            #expect(got.startTimeUs == want.startTimeUs)
        }
    }

    // MARK: rusage v6

    @Test func rusageV6UsesEnergyNJAndConvertsTicks() {
        var ri = rusage_info_v6()
        ri.ri_user_time = 24_000_000          // 1 s
        ri.ri_system_time = 12_000_000        // 0.5 s
        ri.ri_phys_footprint = 123_456_789
        ri.ri_diskio_bytesread = 1_000
        ri.ri_diskio_byteswritten = 2_000
        ri.ri_energy_nj = 3_440_000_000
        ri.ri_billed_energy = 0               // dead field; must not be used
        let v = RusageValues(v6: ri, timebase: MachTimebase(numer: 125, denom: 3))
        #expect(v == RusageValues(cpuTimeNs: 1_500_000_000, footprint: 123_456_789,
                                  diskReadBytes: 1_000, diskWriteBytes: 2_000, energyNJ: 3_440_000_000))
    }

    @Test func rusageV4HasNoEnergy() {
        var ri = rusage_info_v4()
        ri.ri_user_time = 3
        ri.ri_billed_energy = 999
        let v = RusageValues(v4: ri, timebase: MachTimebase(numer: 125, denom: 3))
        #expect(v.cpuTimeNs == 125)
        #expect(v.energyNJ == nil)
    }

    @Test func rusageCPUSumSaturates() {
        var ri = rusage_info_v6()
        ri.ri_user_time = .max
        ri.ri_system_time = .max
        #expect(RusageValues(v6: ri, timebase: MachTimebase(numer: 1, denom: 1)).cpuTimeNs == .max)
    }

    // MARK: builder

    final class FakeSource: ProcessSource {
        var rusageByPID: [Int32: RusageOutcome] = [:]
        var threadsByPID: [Int32: Int32] = [:]
        var names: [Int32: String] = [:]
        var paths: [Int32: String] = [:]
        var responsible: [Int32: Int32] = [:]
        var identityCalls = 0

        func rusage(_ pid: Int32) -> RusageOutcome { rusageByPID[pid] ?? .failed(ESRCH) }
        func threadCount(_ pid: Int32) -> Int32? { threadsByPID[pid] }
        func name(_ pid: Int32) -> String? { identityCalls += 1; return names[pid] }
        func path(_ pid: Int32) -> String? { paths[pid] }
        func responsiblePID(_ pid: Int32) -> Int32? { responsible[pid] }
    }

    static let ok = RusageValues(cpuTimeNs: 10, footprint: 20, diskReadBytes: 30, diskWriteBytes: 40, energyNJ: 50)

    @Test func builderEnrichesPermittedMarksDeniedAndDropsGone() {
        let src = FakeSource()
        src.rusageByPID = [100: .ok(Self.ok), 1: .denied, 200: .gone]
        src.threadsByPID = [100: 7, 1: 99]
        src.names = [100: "Safari Web Content"]
        src.paths = [100: "/Applications/Safari.app/x", 1: "/sbin/launchd"]
        src.responsible = [100: 90]
        var b = ProcessTableBuilder(source: src)
        let rows = b.build([
            KinfoEntry(pid: 100, ppid: 90, uid: 501, comm: "Safari Web Cont", startTimeUs: 5),
            KinfoEntry(pid: 1, ppid: 0, uid: 0, comm: "launchd", startTimeUs: 1),
            KinfoEntry(pid: 200, ppid: 1, uid: 501, comm: "gone", startTimeUs: 9),
        ])
        #expect(rows.count == 2)
        let safari = rows[0]
        #expect(safari == RawProcess(id: ProcessID(pid: 100, startTimeUs: 5), ppid: 90, uid: 501, comm: "Safari Web Cont",
                                     name: "Safari Web Content", path: "/Applications/Safari.app/x", responsiblePID: 90,
                                     cpuTimeNs: 10, footprint: 20, diskReadBytes: 30, diskWriteBytes: 40, energyNJ: 50,
                                     threads: 7, restricted: false))
        let launchd = rows[1]
        #expect(launchd.restricted)
        #expect(launchd.path == "/sbin/launchd")
        #expect(launchd.cpuTimeNs == nil && launchd.footprint == nil && launchd.energyNJ == nil)
        #expect(launchd.threads == nil)   // task info is gated like rusage; not queried
    }

    @Test func builderKeepsRowOnOtherRusageErrors() {
        let src = FakeSource()
        src.rusageByPID = [7: .failed(EINVAL)]
        var b = ProcessTableBuilder(source: src)
        let rows = b.build([KinfoEntry(pid: 7, ppid: 1, uid: 501, comm: "x", startTimeUs: 1)])
        #expect(rows.count == 1)
        #expect(rows[0].restricted == false && rows[0].cpuTimeNs == nil)
    }

    @Test func builderResolvesIdentityOnlyForNewProcessIDs() {
        let src = FakeSource()
        src.rusageByPID = [100: .ok(Self.ok)]
        var b = ProcessTableBuilder(source: src)
        let e = KinfoEntry(pid: 100, ppid: 1, uid: 501, comm: "a", startTimeUs: 5)
        _ = b.build([e])
        _ = b.build([e])
        #expect(src.identityCalls == 1)
        // pid reuse: same pid, new start time → new identity.
        _ = b.build([KinfoEntry(pid: 100, ppid: 1, uid: 501, comm: "a", startTimeUs: 6)])
        #expect(src.identityCalls == 2)
        // exec: same ProcessID, new p_comm → refreshed.
        _ = b.build([KinfoEntry(pid: 100, ppid: 1, uid: 501, comm: "b", startTimeUs: 6)])
        #expect(src.identityCalls == 3)
    }

    @Test func builderPrunesExitedIdentities() {
        let src = FakeSource()
        src.rusageByPID = [1: .ok(Self.ok), 2: .ok(Self.ok)]
        var b = ProcessTableBuilder(source: src)
        _ = b.build([KinfoEntry(pid: 1, ppid: 0, uid: 501, comm: "a", startTimeUs: 1),
                     KinfoEntry(pid: 2, ppid: 0, uid: 501, comm: "b", startTimeUs: 1)])
        #expect(b.cachedIdentityCount == 2)
        _ = b.build([KinfoEntry(pid: 2, ppid: 0, uid: 501, comm: "b", startTimeUs: 1)])
        #expect(b.cachedIdentityCount == 1)
    }

    @Test func builderIgnoresNonPositiveResponsiblePID() {
        let src = FakeSource()
        src.rusageByPID = [3: .ok(Self.ok)]
        src.responsible = [3: 0]
        var b = ProcessTableBuilder(source: src)
        #expect(b.build([KinfoEntry(pid: 3, ppid: 1, uid: 501, comm: "c", startTimeUs: 1)])[0].responsiblePID == nil)
    }
}
