import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

/// Replay invariants (brief T16). Runs on every `Fixtures/recorded/*.json` (W7) plus a synthetic recording that
/// round-trips through the fixture JSON format, so the suite is meaningful before W7's recordings land.
@Suite struct RecordedFixtureTests {
    static func fixtures() throws -> [(name: String, ticks: [RawTick])] {
        let data = try FixtureReplay.encoder.encode(SyntheticRecording.ticks())
        let synthetic = try FixtureReplay.decoder.decode([RawTick].self, from: data)
        return [("synthetic", synthetic)] + (try FixtureReplay.recordedFixtures())
    }

    @Test func usageFractionsStayInRange() throws {
        for (name, ticks) in try Self.fixtures() {
            for step in FixtureReplay.replay(ticks) {
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

    @Test func appCPUMatchesSystemCPUWithRestrictedPidsCovered() throws {
        for (name, ticks) in try Self.fixtures() {
            var checked = 0
            for step in FixtureReplay.replay(ticks) {
                let f = step.frame
                guard let usage = f.cpu.usage, f.interval != nil, !f.apps.isEmpty else { continue }
                let cores = Double(ticks.last?.hostCPU.value?.cores.count ?? 0)
                let systemPercent = usage * cores * 100
                guard systemPercent >= 20 else { continue }             // idle noise: nothing to compare
                let appPercent = f.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
                #expect(abs(appPercent - systemPercent) <= 0.15 * systemPercent,
                        "\(name) @\(f.uptimeNs): apps \(appPercent) % vs system \(systemPercent) %")
                // every restricted pid in a coalition with a delta is represented by a filled or synthetic row
                for p in f.processes where p.provenance == .restricted {
                    guard let cid = p.coalitionID else { continue }
                    #expect(f.processes.contains { $0.coalitionID == cid && $0.provenance == .coalition },
                            "\(name): restricted pid \(p.pid) not covered by a coalition row")
                }
                checked += 1
            }
            #expect(checked > 0 || name != "synthetic")
        }
    }

    @Test func helpersGroupUnderTheirResponsibleApp() throws {
        for (name, ticks) in try Self.fixtures() {
            guard let step = FixtureReplay.replay(ticks).last, let raw = step.tick.processes.value else { continue }
            let byPID = Dictionary(raw.processes.map { ($0.id.pid, $0) }, uniquingKeysWith: { a, _ in a })
            let rows = Dictionary(step.frame.processes.filter { !$0.id.isSynthetic }.map { ($0.pid, $0) },
                                  uniquingKeysWith: { a, _ in a })
            for p in raw.processes {
                guard let r = p.responsiblePID, r != p.id.pid, let parent = byPID[r],
                      parent.responsiblePID == nil || parent.responsiblePID == r else { continue }
                #expect(rows[p.id.pid]?.app == rows[r]?.app, "\(name): pid \(p.id.pid) not grouped with responsible \(r)")
            }
        }
    }

    @Test func noSpikeAfterWake() throws {
        for (name, ticks) in try Self.fixtures() {
            let steps = FixtureReplay.replay(ticks)
            let cores = Double(ticks.last?.hostCPU.value?.cores.count ?? 0)
            for (i, step) in steps.enumerated() {
                if step.afterWake {
                    #expect(step.frame.interval == nil, "\(name): post-wake frame must have no rates")
                    #expect(step.frame.processes.allSatisfy { $0.cpuPercent == nil || $0.id.isSynthetic },
                            "\(name): post-wake process rates")
                }
                if cores > 0, step.frame.interval != nil {
                    let appPercent = step.frame.apps.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
                    #expect(appPercent <= cores * 100 * 1.15, "\(name) frame \(i): \(appPercent) % on \(Int(cores)) cores")
                }
            }
            if name == "synthetic" { #expect(steps.contains { $0.afterWake }) }
        }
    }
}
