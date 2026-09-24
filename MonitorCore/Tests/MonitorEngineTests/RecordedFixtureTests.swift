import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

/// Replay invariants (brief T16), through the real `SamplingEngine`. Runs on every `Fixtures/recorded/*.json`
/// (W7, `RawTick.fixtureDecoder` format) plus a synthetic recording that round-trips through the fixture coders.
@Suite struct RecordedFixtureTests {
    static func fixtures() throws -> [(name: String, ticks: [RawTick])] {
        let data = try RawTick.fixtureEncoder.encode(SyntheticRecording.ticks())
        let synthetic = try RawTick.fixtureDecoder.decode([RawTick].self, from: data)
        let recorded = try FixtureReplay.recordedFixtures()
        if recorded.isEmpty {
            print("RecordedFixtureTests: no Fixtures/recorded/*.json yet (W7) — synthetic recording only")
        }
        return [("synthetic", synthetic)] + recorded
    }

    // MARK: format

    @Test func fixtureCodersRoundTripSubSecondDates() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000.125)          // exactly representable
        let tick = RawTick(wallTime: date, uptimeNs: 42, mode: .interactive,
                           thermalState: .fresh(.fair, capturedNs: 41))
        let data = try RawTick.fixtureEncoder.encode([tick])
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("2026-09-21T") && json.contains(".125Z"))         // ISO 8601, fractional seconds, UTC
        let back = try RawTick.fixtureDecoder.decode([RawTick].self, from: data)
        #expect(abs(back[0].wallTime.timeIntervalSince(date)) < 0.001)
        #expect(back[0].uptimeNs == 42)
        #expect(back[0].thermalState.value == .fair)
        #expect(back[0].processes.value == nil)                                  // missing sensors → notRequested
    }

    @Test func fixtureDecoderAcceptsWholeSecondStamps() throws {
        let json = #"[{"wallTime":"2026-09-21T10:00:00Z","uptimeNs":1,"mode":"background"}]"#
        let ticks = try RawTick.fixtureDecoder.decode([RawTick].self, from: Data(json.utf8))
        #expect(ticks.first?.mode == .background)
    }

    // MARK: invariants

    @Test func usageFractionsStayInRange() async throws {
        for (name, ticks) in try Self.fixtures() {
            for step in await FixtureReplay.replayThroughEngine(ticks) {
                let f = step.frame
                for (label, v) in [("cpu", f.cpu.usage), ("user", f.cpu.user), ("system", f.cpu.system), ("idle", f.cpu.idle),
                                   ("gpu", f.gpu.usage), ("pressure", f.memory.pressureFraction)] {
                    if let v { #expect((0...1).contains(v), "\(name) \(label) = \(v)") }
                }
                for c in f.cpu.cores { #expect((0...1).contains(c.usage), "\(name) core \(c.index)") }
                for c in f.cpu.clusters { if let u = c.usage { #expect((0...1).contains(u), "\(name) cluster") } }
            }
        }
    }

    /// Σ app CPU ≈ system CPU × cores × 100: within 15 % when busy, within 20 points when idle — every frame with
    /// rates is checked, so an idle recording can't pass unchecked.
    @Test func appCPUMatchesSystemCPUWithRestrictedPidsCovered() async throws {
        for (name, ticks) in try Self.fixtures() {
            var checked = 0
            for step in await FixtureReplay.replayThroughEngine(ticks) {
                let f = step.frame
                guard let usage = f.cpu.usage, f.interval != nil, !f.apps.isEmpty else { continue }
                let cores = Double(step.tick.hostCPU.value?.cores.count ?? 0)
                let systemPercent = usage * cores * 100
                let appPercent = f.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
                #expect(abs(appPercent - systemPercent) <= max(0.15 * systemPercent, 20),
                        "\(name) @\(f.uptimeNs): apps \(appPercent) % vs system \(systemPercent) %")
                for p in f.processes where p.provenance == .restricted {
                    guard let cid = p.coalitionID else { continue }
                    #expect(f.processes.contains { $0.coalitionID == cid && $0.provenance == .coalition },
                            "\(name): restricted pid \(p.pid) not covered by a coalition row")
                }
                checked += 1
            }
            #expect(checked > 0, "\(name): no frame with rates was checked")
        }
    }

    @Test func helpersGroupUnderTheirResponsibleApp() async throws {
        for (name, ticks) in try Self.fixtures() {
            guard let step = await FixtureReplay.replayThroughEngine(ticks).last,
                  let raw = step.tick.processes.value else { continue }
            let byPID = Dictionary(raw.processes.map { ($0.id.pid, $0) }, uniquingKeysWith: { a, _ in a })
            let rows = Dictionary(step.frame.processes.filter { !$0.id.isSynthetic }.map { ($0.pid, $0) },
                                  uniquingKeysWith: { a, _ in a })
            var checked = 0
            for p in raw.processes {
                guard let r = p.responsiblePID, r != p.id.pid, let parent = byPID[r],
                      parent.responsiblePID == nil || parent.responsiblePID == r else { continue }
                #expect(rows[p.id.pid]?.app == rows[r]?.app, "\(name): pid \(p.id.pid) not grouped with responsible \(r)")
                checked += 1
            }
            if name == "synthetic" { #expect(checked == 2) }
        }
    }

    @Test func noSpikeAfterWake() async throws {
        for (name, ticks) in try Self.fixtures() {
            let steps = await FixtureReplay.replayThroughEngine(ticks)
            let cores = Double(ticks.last?.hostCPU.value?.cores.count ?? 0)
            for (i, step) in steps.enumerated() {
                if step.afterWake {
                    #expect(step.frame.interval == nil, "\(name): post-wake frame must have no rates")
                    #expect(step.frame.cpu.usage == nil, "\(name): post-wake system CPU")
                    #expect(step.frame.processes.allSatisfy { $0.cpuPercent == nil }, "\(name): post-wake process rates")
                }
                if cores > 0 {
                    let appPercent = step.frame.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
                    #expect(appPercent <= cores * 100 * 1.15, "\(name) frame \(i): \(appPercent) % on \(Int(cores)) cores")
                }
            }
            if name == "synthetic" { #expect(steps.contains { $0.afterWake }) }
        }
    }

    /// The guard matters: the same synthetic recording replayed without the wake reset spikes.
    @Test func withoutWakeResetTheSyntheticRecordingSpikes() {
        let frames = FixtureReplay.replayWithoutWakeReset(SyntheticRecording.ticks())
        let wake = frames[SyntheticRecording.wakeAt]
        let appPercent = wake.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
        #expect(appPercent > Double(SyntheticRecording.cores) * 100 * 10)
    }
}
