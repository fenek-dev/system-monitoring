import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

/// ICR-14: per-process disk bytes since Telltale started.
@Suite struct DiskSessionBaselinesTests {
    static let startUs: UInt64 = 1_790_000_000_000_000

    func proc(_ pid: Int32, start: UInt64, r: UInt64?, w: UInt64?) -> RawProcess {
        own(pid, start: start, diskR: r, diskW: w)
    }

    @Test func newbornCountsInFull() {
        var d = DiskSessionBaselines()
        d.start(atUs: Self.startUs)
        let s = d.session(proc(10, start: Self.startUs + 5, r: 4_000, w: 9_000))
        #expect(s.read == 4_000 && s.write == 9_000)
        #expect(d.session(proc(10, start: Self.startUs + 5, r: 6_000, w: 9_500)) == (6_000, 9_500))
    }

    @Test func predatingProcessCountsFromItsFirstSample() {
        var d = DiskSessionBaselines()
        d.start(atUs: Self.startUs)
        #expect(d.session(proc(10, start: 1, r: 171_000_000_000, w: 5)) == (0, 0))   // lifetime ≠ session
        #expect(d.session(proc(10, start: 1, r: 171_000_001_000, w: 5)) == (1_000, 0))
    }

    @Test func pidReuseWithNewStartTimeGetsAFreshBaseline() {
        var d = DiskSessionBaselines()
        d.start(atUs: Self.startUs)
        _ = d.session(proc(10, start: 1, r: 50_000, w: 0))
        d.prune(keeping: [])                                                   // exited
        #expect(d.count == 0)
        // Same pid, new start time after the session began → a newborn: full count, not relative to the old one.
        #expect(d.session(proc(10, start: Self.startUs + 60, r: 700, w: 0)) == (700, 0))
    }

    @Test func counterGoingBackwardsRebases() {
        var d = DiskSessionBaselines()
        d.start(atUs: Self.startUs)
        _ = d.session(proc(10, start: 1, r: 5_000, w: 5_000))
        _ = d.session(proc(10, start: 1, r: 8_000, w: 5_000))
        #expect(d.session(proc(10, start: 1, r: 100, w: 5_000)) == (0, 0))        // backwards: rebase, no wrap
        #expect(d.session(proc(10, start: 1, r: 400, w: 5_100)) == (300, 100))
    }

    @Test func olderEncodingsDecodeWithoutSessionFields() throws {
        let data = try JSONEncoder().encode(ProcessSample(id: ProcessID(pid: 3, startTimeUs: 1), diskReadSession: 9))
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["diskReadSession"] as? Int == 9)
        obj["diskReadSession"] = nil
        let back = try JSONDecoder().decode(ProcessSample.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.diskReadSession == nil && back.diskWriteSession == nil)
    }

    @Test func missingCounterIsNil() {
        var d = DiskSessionBaselines()
        d.start(atUs: Self.startUs)
        #expect(d.session(proc(10, start: 1, r: nil, w: 3)) == (nil, 0))
    }

    @Test func processAssemblerFillsSessionAndSurvivesWake() throws {
        var pa = ProcessAssembler(currentUID: testUID)
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
        let apps = AppGrouper.group([ProcessSample(id: p.id, app: p.app, diskReadSession: 5_000),
                                     ProcessSample(id: ProcessID(pid: 11, startTimeUs: 1), app: p.app, diskReadSession: 7)],
                                    identities: [:])
        #expect(apps.first?.diskReadSession == 5_007)
    }
}

private func == (a: (read: UInt64?, write: UInt64?), b: (UInt64?, UInt64?)) -> Bool {
    a.read == b.0 && a.write == b.1
}
