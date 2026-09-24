import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

/// ICR-14: disk bytes since Telltale started (session start = Telltale's own process start).
@Suite struct DiskSessionBaselinesTests {
    static let startUs: UInt64 = 1_790_000_000_000_000

    func proc(_ pid: Int32, start: UInt64, r: UInt64?, w: UInt64?) -> RawProcess {
        own(pid, start: start, diskR: r, diskW: w)
    }

    @Test func newbornCountsInFull() {
        var d = DiskSessionBaselines(sessionStartUs: Self.startUs)
        let s = d.session(proc(10, start: Self.startUs + 5, r: 4_000, w: 9_000))
        #expect(s.read == 4_000 && s.write == 9_000)
        #expect(d.session(proc(10, start: Self.startUs + 5, r: 6_000, w: 9_500)) == (6_000, 9_500))
    }

    @Test func startedExactlyAtSessionStartIsANewborn() {
        var d = DiskSessionBaselines(sessionStartUs: Self.startUs)
        #expect(d.session(proc(10, start: Self.startUs, r: 700, w: 0)) == (700, 0))
        #expect(d.session(proc(11, start: Self.startUs - 1, r: 700, w: 0)) == (0, 0))
    }

    @Test func predatingProcessCountsFromItsFirstSample() {
        var d = DiskSessionBaselines(sessionStartUs: Self.startUs)
        #expect(d.session(proc(10, start: 1, r: 171_000_000_000, w: 5)) == (0, 0))   // lifetime ≠ session
        #expect(d.session(proc(10, start: 1, r: 171_000_001_000, w: 5)) == (1_000, 0))
    }

    @Test func pidReuseWithNewStartTimeGetsAFreshBaseline() {
        var d = DiskSessionBaselines(sessionStartUs: Self.startUs)
        _ = d.session(proc(10, start: 1, r: 50_000, w: 0))
        d.prune(keeping: [])                                                   // exited
        #expect(d.count == 0)
        // Same pid, new start time after the session began → a newborn: full count, not relative to the old one.
        #expect(d.session(proc(10, start: Self.startUs + 60, r: 700, w: 0)) == (700, 0))
    }

    @Test func counterGoingBackwardsRebasesMonotonically() {
        var d = DiskSessionBaselines(sessionStartUs: Self.startUs)
        #expect(d.session(proc(10, start: 1, r: 5_000, w: 5_000)).firstSight)
        let a = d.session(proc(10, start: 1, r: 8_000, w: 5_000))
        #expect(a == (3_000, 0) && a.deltaRead == 3_000 && !a.firstSight)
        let b = d.session(proc(10, start: 1, r: 100, w: 5_000))
        #expect(b == (3_000, 0) && b.deltaRead == 0)                          // backwards: keeps 3 000, no wrap
        let c = d.session(proc(10, start: 1, r: 400, w: 5_100))
        #expect(c == (3_300, 100) && c.deltaRead == 300 && c.deltaWrite == 100)
    }

    @Test func missingCounterIsNil() {
        var d = DiskSessionBaselines(sessionStartUs: Self.startUs)
        #expect(d.session(proc(10, start: 1, r: nil, w: 3)) == (nil, 0))
    }

    @Test func olderEncodingsDecodeWithoutSessionFields() throws {
        let data = try JSONEncoder().encode(ProcessSample(id: ProcessID(pid: 3, startTimeUs: 1), diskReadSession: 9))
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["diskReadSession"] as? Int == 9)
        obj["diskReadSession"] = nil
        let back = try JSONDecoder().decode(ProcessSample.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.diskReadSession == nil && back.diskWriteSession == nil)
    }

    @Test func processAssemblerFillsSessionAndSurvivesWake() throws {
        var pa = ProcessAssembler(currentUID: testUID, sessionStartUs: Self.startUs)
        let resolver = FixtureAppResolver([10: appID("a")])
        let w0 = Date(timeIntervalSince1970: 1_790_000_000)
        func tick(_ r: UInt64, at t: UInt64) -> ProcessAssembly {
            pa.assemble(ProcessInputs(processes: table([own(10, start: 1, diskR: r, diskW: 0)], at: t), uptimeNs: t,
                                      wallTime: w0.addingTimeInterval(Double(t / sec))), resolver: resolver)
        }
        #expect(tick(1_000_000, at: sec).samples[pid: 10]?.diskReadSession == 0)
        #expect(tick(1_004_000, at: 2 * sec).samples[pid: 10]?.diskReadSession == 4_000)
        pa.reset()                                                              // wake: rates restart, session doesn't
        let p = try #require(tick(1_005_000, at: 3 * sec).samples[pid: 10])
        #expect(p.diskReadSession == 5_000 && p.diskReadTotal == 1_005_000)
    }

    /// App session is accumulated (ruling): a helper exiting doesn't lower it.
    @Test func appSessionNeverDropsWhenAHelperExits() throws {
        let a = AppIdentity(key: AppKey(kind: .app, id: "a"), displayName: "a")
        var fa = FrameAssembler(resolver: FixtureAppResolver([10: a, 11: a]), currentUID: testUID, sessionStartUs: Self.startUs)
        func tick(_ n: UInt64, helper: Bool) -> RawTick {
            var ps = [own(10, cpuNs: n * sec / 10, diskR: n * 1_000, diskW: 0)]
            if helper { ps.append(own(11, cpuNs: n * sec / 10, diskR: n * 500, diskW: n * 100, responsible: 10)) }
            return RawTick(wallTime: Date(timeIntervalSince1970: 1_790_000_100 + Double(n)), uptimeNs: n * sec,
                           mode: .interactive, processes: .fresh(ProcessTableReading(processes: ps), capturedNs: n * sec))
        }
        _ = fa.assemble(tick(1, helper: true), inspectedApp: nil)
        let before = try #require(fa.assemble(tick(3, helper: true), inspectedApp: nil).apps.first { $0.identity.key == a.key })
        #expect(before.diskReadSession == 2 * 1_500 && before.diskWriteSession == 2 * 100)
        let after = try #require(fa.assemble(tick(4, helper: false), inspectedApp: nil).apps.first { $0.identity.key == a.key })
        #expect(after.diskReadSession == 3_000 + 1_000)                         // helper gone; its 1 000 B stay
        #expect(after.diskWriteSession == 200)
        fa.reset()                                                              // wake: the app session keeps growing
        let woke = try #require(fa.assemble(tick(6, helper: false), inspectedApp: nil).apps.first { $0.identity.key == a.key })
        #expect(woke.diskReadSession == 4_000 + 2_000)                          // Δ of pid 10's session over the gap
    }

    @Test func appWithoutDiskCountersHasNilDiskSession() throws {
        let a = AppIdentity(key: AppKey(kind: .app, id: "a"), displayName: "a")
        var fa = FrameAssembler(resolver: FixtureAppResolver([10: a]), currentUID: testUID, sessionStartUs: Self.startUs)
        func tick(_ n: UInt64) -> RawTick {
            RawTick(wallTime: Date(timeIntervalSince1970: 1_790_000_100 + Double(n)), uptimeNs: n * sec, mode: .interactive,
                    processes: .fresh(ProcessTableReading(processes: [own(10, cpuNs: n * sec / 10, diskR: nil, diskW: nil)]),
                                      capturedNs: n * sec))
        }
        _ = fa.assemble(tick(1), inspectedApp: nil)
        let app = try #require(fa.assemble(tick(2), inspectedApp: nil).apps.first { $0.identity.key == a.key })
        #expect(app.diskReadSession == nil && app.diskWriteSession == nil)      // unknown, not 0
        #expect(app.cpuTimeNs == sec / 10)
    }
}

private func == (a: DiskSessionBaselines.Result, b: (UInt64?, UInt64?)) -> Bool {
    a.read == b.0 && a.write == b.1
}
