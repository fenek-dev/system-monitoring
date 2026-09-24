import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

private func measured(_ pid: Int32, cid: UInt64, cpu: Double?, diskR: Double? = 0, diskW: Double? = 0,
                      gpu: Double? = nil, watts: Double? = nil) -> ProcessSample {
    ProcessSample(id: ProcessID(pid: pid, startTimeUs: 1), name: "m\(pid)", uid: testUID, isCurrentUser: true,
                  app: AppKey(kind: .app, id: "m\(pid)"), provenance: .measured, coalitionID: cid, cpuPercent: cpu,
                  gpuPercent: gpu, diskReadBps: diskR, diskWriteBps: diskW, energyWatts: watts)
}

private func restricted(_ pid: Int32, cid: UInt64, name: String? = nil, gpu: Double? = nil) -> ProcessSample {
    ProcessSample(id: ProcessID(pid: pid, startTimeUs: 1), name: name ?? "r\(pid)", user: "root", uid: 0,
                  app: AppKey(kind: .process, id: name ?? "r\(pid)"), provenance: .restricted, coalitionID: cid,
                  gpuPercent: gpu)
}

/// Coalition delta over 1 s: `cpu` percent of one core, `diskR`/`diskW` B/s, `watts`.
private func delta(cpu: Double, diskR: Double? = 0, diskW: Double? = 0, watts: Double? = nil, seconds: Double = 1) -> CoalitionDelta {
    CoalitionDelta(cpuNs: UInt64((cpu * 1e7 * seconds).rounded()), energyNJ: watts.map { UInt64(($0 * 1e9 * seconds).rounded()) },
                   diskR: diskR.map { UInt64(($0 * seconds).rounded()) }, diskW: diskW.map { UInt64(($0 * seconds).rounded()) },
                   seconds: seconds)
}

private func deltas(_ d: [UInt64: (CoalitionDelta, leader: Int32?, members: [Int32])]) -> CoalitionDeltas {
    CoalitionDeltas(byID: d.mapValues(\.0),
                    membership: Dictionary(uniqueKeysWithValues: d.map { ($0.key, CoalitionUsage(id: $0.key, leaderPID: $0.value.leader,
                                                                                                 memberPIDs: $0.value.members)) }))
}

@Suite struct CoalitionAttributorTests {
    @Test func singleRestrictedMemberGetsResidual() throws {
        var ps = [measured(10, cid: 5, cpu: 20, diskR: 100, diskW: 0), restricted(418, cid: 5, name: "WindowServer")]
        var ca = CoalitionAttributor()
        let synthetic = ca.attribute(&ps, coalitions: deltas([5: (delta(cpu: 70, diskR: 400, diskW: 50), 10, [10, 418])]),
                                     identities: [:])
        #expect(synthetic.isEmpty)
        let r = try #require(ps[pid: 418])
        #expect(r.provenance == .coalition)
        #expect(abs(r.cpuPercent! - 50) < 1e-9)
        #expect(r.diskReadBps == 300)
        #expect(r.diskWriteBps == 50)
        #expect(r.coalitionLeaderName == "m10")
        #expect(ps[pid: 10]?.cpuPercent == 20)                // visible member untouched
    }

    @Test func residualClampedAtZero() throws {
        var ps = [measured(10, cid: 5, cpu: 30), restricted(418, cid: 5)]
        var ca = CoalitionAttributor()
        _ = ca.attribute(&ps, coalitions: deltas([5: (delta(cpu: 29), 418, [10, 418])]), identities: [:])
        #expect(ps[pid: 418]?.cpuPercent == 0)
    }

    @Test func missingCoalitionDiskLeavesDiskNil() {
        var ps = [restricted(418, cid: 5)]
        var ca = CoalitionAttributor()
        _ = ca.attribute(&ps, coalitions: deltas([5: (delta(cpu: 10, diskR: nil, diskW: nil), 418, [418])]), identities: [:])
        #expect(ps[pid: 418]?.cpuPercent == 10)
        #expect(ps[pid: 418]?.diskReadBps == nil)
    }

    @Test func severalRestrictedMembersGetOneSyntheticRowNamedAfterLeader() throws {
        var ps = [restricted(1, cid: 1, name: "launchd"), restricted(0, cid: 1, name: "kernel_task"),
                  measured(50, cid: 1, cpu: 2)]
        let launchdApp = AppIdentity(key: AppKey(kind: .process, id: "/sbin/launchd"), displayName: "launchd")
        var ca = CoalitionAttributor()
        let synthetic = ca.attribute(&ps, coalitions: deltas([1: (delta(cpu: 35, diskR: 10, diskW: 20), 1, [0, 1, 50])]),
                                     identities: [1: launchdApp])
        let row = try #require(synthetic.first)
        #expect(synthetic.count == 1)
        #expect(row.id == .coalitionResidual(1))
        #expect(row.id.isSynthetic)
        #expect(row.name == "launchd")
        #expect(row.app == launchdApp.key)
        #expect(row.provenance == .coalition)
        #expect(row.coalitionID == 1)
        #expect(abs(row.cpuPercent! - 33) < 1e-9)
        #expect(row.diskReadBps == 10 && row.diskWriteBps == 20)
        #expect(row.gpuPercent == nil)                        // coalition gpu_time is never used
        #expect(row.coalitionLeaderName == "launchd")
        // restricted members stay restricted, values nil, but know their leader
        #expect(ps[pid: 0]?.provenance == .restricted)
        #expect(ps[pid: 0]?.cpuPercent == nil)
        #expect(ps[pid: 0]?.coalitionLeaderName == "launchd")
    }

    @Test func noLeaderMeansSystem() throws {
        var ps = [restricted(7, cid: 9), restricted(8, cid: 9)]
        var ca = CoalitionAttributor()
        let row = try #require(ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 5), nil, [7, 8])]), identities: [:]).first)
        #expect(row.name == "System")
        #expect(row.app == .system)
        #expect(row.coalitionLeaderName == nil)
    }

    @Test func leaderNotInProcessListMeansSystem() throws {
        var ps = [restricted(7, cid: 9), restricted(8, cid: 9)]
        var ca = CoalitionAttributor()
        let row = try #require(ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 5), 3, [7, 8])]), identities: [:]).first)
        #expect(row.app == .system)
        #expect(row.name == "System")
    }

    @Test func tinyResidualBelowThresholdsMakesNoSyntheticRow() {
        // one measured member with a v6 value → v6 mode
        var ps = [restricted(7, cid: 9), restricted(8, cid: 9), measured(20, cid: 9, cpu: 0, watts: 0.1)]
        var ca = CoalitionAttributor(minResidualCPUPercent: 0.5, minResidualWatts: 0.05)
        #expect(ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 0.2, watts: 0.12), 7, [7, 8, 20])]), identities: [:]).isEmpty)
        // energy residual alone above its threshold is enough (v6 mode)
        #expect(ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 0.2, watts: 0.5), 7, [7, 8, 20])]), identities: [:]).count == 1)
        // disk alone is enough
        #expect(ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 0, diskR: 4_096), 7, [7, 8, 20])]), identities: [:]).count == 1)
    }

    @Test func fallbackModeEnergyDoesNotMakeRowsSignificant() {
        // no measured v6 anywhere: whole-coalition watts must not create a row for a tiny CPU residual
        var ps = [restricted(7, cid: 9), restricted(8, cid: 9), measured(20, cid: 9, cpu: 0)]
        var ca = CoalitionAttributor()
        #expect(ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 0.2, watts: 3), 7, [7, 8, 20])]), identities: [:]).isEmpty)
    }

    @Test func belowThresholdTooltipNamesLeaderApp() {
        var ps = [restricted(7, cid: 9, name: "backupd"), restricted(8, cid: 9)]
        var ca = CoalitionAttributor()
        let app = AppIdentity(key: AppKey(kind: .app, id: "com.apple.TimeMachine"), displayName: "Time Machine")
        #expect(ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 0.1), 7, [7, 8])]), identities: [7: app]).isEmpty)
        #expect(ps[pid: 8]?.coalitionLeaderName == "Time Machine")
    }

    @Test func leaderNameSetEvenWithoutDelta() {
        var ps = [restricted(7, cid: 9, name: "WindowServer"), restricted(8, cid: 9)]
        var ca = CoalitionAttributor()
        let firstTick = CoalitionDeltas(byID: [:], membership: [9: CoalitionUsage(id: 9, leaderPID: 7, memberPIDs: [7, 8])])
        #expect(ca.attribute(&ps, coalitions: firstTick, identities: [:]).isEmpty)
        #expect(ps[pid: 8]?.coalitionLeaderName == "WindowServer")
        #expect(ps[pid: 8]?.provenance == .restricted)
    }

    @Test func leaderPidOutsideTheCoalitionIsNotTheLeader() throws {
        // pid 7 was the leader of coalition 9 but got reused by a process in coalition 3
        var ps = [measured(7, cid: 3, cpu: 1), restricted(8, cid: 9), restricted(10, cid: 9)]
        var ca = CoalitionAttributor()
        let row = try #require(ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 5), 7, [8, 10])]), identities: [:]).first)
        #expect(row.name == "System" && row.app == .system)
    }

    // Ruling: keep the single-fill rule. A visible member that exits mid-interval is missing from Σ visible, so its
    // last-interval work leaks into the residual.
    @Test func exitedVisibleMemberLeaksIntoSingleFill() {
        // coalition work 70 % = restricted 30 % + live visible 20 % + visible that exited 20 %
        var ps = [measured(10, cid: 5, cpu: 20), restricted(418, cid: 5)]
        var ca = CoalitionAttributor()
        _ = ca.attribute(&ps, coalitions: deltas([5: (delta(cpu: 70), 10, [10, 418])]), identities: [:])
        #expect(abs(ps[pid: 418]!.cpuPercent! - 50) < 1e-9)   // 30 + the exited member's 20
    }

    @Test func exitedVisibleMemberLeaksIntoSyntheticRowOfLeaderApp() throws {
        let leaderApp = AppIdentity(key: AppKey(kind: .app, id: "com.x.leader"), displayName: "Leader")
        var ps = [measured(10, cid: 5, cpu: 20), restricted(418, cid: 5), restricted(419, cid: 5)]
        var ca = CoalitionAttributor()
        let row = try #require(ca.attribute(&ps, coalitions: deltas([5: (delta(cpu: 70), 10, [10, 418, 419])]),
                                            identities: [10: leaderApp]).first)
        #expect(abs(row.cpuPercent! - 50) < 1e-9)
        #expect(row.app == leaderApp.key)
    }

    @Test func singleRestrictedMemberFilledEvenBelowThreshold() {
        var ps = [restricted(7, cid: 9)]
        var ca = CoalitionAttributor()
        _ = ca.attribute(&ps, coalitions: deltas([9: (delta(cpu: 0.1), 7, [7])]), identities: [:])
        #expect(abs(ps[pid: 7]!.cpuPercent! - 0.1) < 1e-9)
    }

    @Test func allVisibleCoalitionIsLeftToRusage() {
        let before = [measured(10, cid: 3, cpu: 40), measured(11, cid: 3, cpu: 10)]
        var ps = before
        var ca = CoalitionAttributor()
        // coalition meter reads 1 % higher than Σ rusage: must NOT produce a residual row
        let synthetic = ca.attribute(&ps, coalitions: deltas([3: (delta(cpu: 50.5), 10, [10, 11])]), identities: [:])
        #expect(synthetic.isEmpty)
        #expect(ps == before)
    }

    @Test func coalitionWithoutDeltaIsSkipped() {
        var ps = [restricted(7, cid: 9), restricted(8, cid: 9)]
        var ca = CoalitionAttributor()
        #expect(ca.attribute(&ps, coalitions: CoalitionDeltas(byID: [:], membership: [:]), identities: [:]).isEmpty)
        #expect(ps[pid: 7]?.provenance == .restricted)
        #expect(ps[pid: 7]?.coalitionLeaderName == nil)
    }

    @Test func restrictedGPUFromAGXIsKept() {
        var ps = [restricted(418, cid: 5, gpu: 12)]
        var ca = CoalitionAttributor()
        _ = ca.attribute(&ps, coalitions: deltas([5: (delta(cpu: 10), 418, [418])]), identities: [:])
        #expect(ps[pid: 418]?.gpuPercent == 12)
    }

    // MARK: property: no double counting

    @Test func noDoubleCountProperty() {
        var rng = SplitMix64(seed: 0x7e11_7a1e)
        var ca = CoalitionAttributor(minResidualCPUPercent: 0, minResidualWatts: 0)
        for round in 0..<200 {
            var ps: [ProcessSample] = []
            var byID: [UInt64: (CoalitionDelta, leader: Int32?, members: [Int32])] = [:]
            var pid: Int32 = 1
            let coalitionCount = Int.random(in: 1...6, using: &rng)
            for c in 0..<coalitionCount {
                let cid = UInt64(round * 10 + c + 1)
                let visible = Int.random(in: 0...4, using: &rng)
                let hidden = Int.random(in: 0...3, using: &rng)
                guard visible + hidden > 0 else { continue }
                var members: [Int32] = []
                var visCPU = 0.0, visR = 0.0, visW = 0.0
                for _ in 0..<visible {
                    let cpu = Double.random(in: 0...150, using: &rng)
                    let r = Double(Int.random(in: 0...10_000, using: &rng)), w = Double(Int.random(in: 0...10_000, using: &rng))
                    ps.append(measured(pid, cid: cid, cpu: cpu, diskR: r, diskW: w))
                    visCPU += cpu; visR += r; visW += w
                    members.append(pid); pid += 1
                }
                for _ in 0..<hidden {
                    ps.append(restricted(pid, cid: cid))
                    members.append(pid); pid += 1
                }
                // coalition meter ≥ Σ visible (the residual is the restricted members' share), or ~1 % off when all visible
                let extraCPU = hidden > 0 ? Double.random(in: 0...200, using: &rng) : visCPU * 0.01
                let extraR = Double(Int.random(in: 0...50_000, using: &rng)), extraW = Double(Int.random(in: 0...50_000, using: &rng))
                let seconds = Double.random(in: 0.5...5, using: &rng)
                let d = CoalitionDelta(cpuNs: UInt64(((visCPU + extraCPU) * 1e7 * seconds).rounded(.up)), energyNJ: nil,
                                       diskR: UInt64(((visR + extraR) * seconds).rounded(.up)),
                                       diskW: UInt64(((visW + extraW) * seconds).rounded(.up)),
                                       seconds: seconds)
                byID[cid] = (d, members.randomElement(using: &rng), members)
            }
            let before = ps
            let synthetic = ca.attribute(&ps, coalitions: deltas(byID), identities: [:])
            let all = ps + synthetic
            for (cid, entry) in byID {
                let rows = all.filter { $0.coalitionID == cid }
                let hasRestricted = before.contains { $0.coalitionID == cid && $0.provenance == .restricted }
                if hasRestricted {
                    let d = entry.0
                    let cpu = Double(d.cpuNs) / d.seconds / 1e7
                    #expect(abs(rows.reduce(0) { $0 + ($1.cpuPercent ?? 0) } - cpu) < 1e-9 * max(1, cpu), "round \(round) cid \(cid) cpu")
                    #expect(abs(rows.reduce(0) { $0 + ($1.diskReadBps ?? 0) } - Double(d.diskR!) / d.seconds) < 1e-6, "round \(round) cid \(cid) diskR")
                    #expect(abs(rows.reduce(0) { $0 + ($1.diskWriteBps ?? 0) } - Double(d.diskW!) / d.seconds) < 1e-6, "round \(round) cid \(cid) diskW")
                    #expect(synthetic.filter { $0.coalitionID == cid }.count <= 1)
                } else {
                    #expect(rows == before.filter { $0.coalitionID == cid }, "all-visible coalition changed")
                    #expect(!synthetic.contains { $0.coalitionID == cid })
                }
            }
        }
    }

    /// Default thresholds, clamp cases, nil-CPU visible members, v6 energy; invariants at row, app and energy level.
    @Test func noDoubleCountAppLevelAndEnergyProperty() {
        var rng = SplitMix64(seed: 0xC0A1_1710)
        let apps = (0..<5).map { AppKey(kind: .app, id: "app\($0)") }
        var clampRounds = 0, droppedRounds = 0
        for round in 0..<200 {
            var ca = CoalitionAttributor()                           // 0.5 %, 0.05 W
            var ps: [ProcessSample] = []
            var byID: [UInt64: (CoalitionDelta, leader: Int32?, members: [Int32])] = [:]
            var expectedResidualCPU: [UInt64: Double] = [:]          // emitted residual per restricted coalition
            var visCPUByID: [UInt64: Double] = [:], visWattsByID: [UInt64: Double] = [:], coalWatts: [UInt64: Double] = [:]
            var pid: Int32 = 1
            for c in 0..<Int.random(in: 1...6, using: &rng) {
                let cid = UInt64(round * 10 + c + 1)
                let visible = Int.random(in: 0...4, using: &rng), hidden = Int.random(in: 0...3, using: &rng)
                guard visible + hidden > 0 else { continue }
                var members: [Int32] = []
                var visCPU = 0.0, visR = 0.0, visW = 0.0, visWatts = 0.0
                for _ in 0..<visible {
                    let cpu: Double? = Int.random(in: 0..<10, using: &rng) == 0 ? nil : Double.random(in: 0...150, using: &rng)
                    let r = Double(Int.random(in: 0...10_000, using: &rng)), w = Double(Int.random(in: 0...10_000, using: &rng))
                    let watts = Double.random(in: 0...3, using: &rng)
                    var p = measured(pid, cid: cid, cpu: cpu, diskR: r, diskW: w, watts: watts)
                    p.app = apps.randomElement(using: &rng)!
                    ps.append(p)
                    visCPU += cpu ?? 0; visR += r; visW += w; visWatts += watts
                    members.append(pid); pid += 1
                }
                for _ in 0..<hidden {
                    ps.append(restricted(pid, cid: cid))
                    members.append(pid); pid += 1
                }
                let mode = Int.random(in: 0..<6, using: &rng)
                let seconds = Double.random(in: 0.5...5, using: &rng)
                // mode 0: coalition below Σ visible (clamp); mode 1: tiny residual, no disk (threshold drop); else normal
                let cpuC = mode == 0 ? visCPU * 0.9 : (mode == 1 ? visCPU + 0.1 : visCPU + Double.random(in: 0...200, using: &rng))
                let extraR = mode <= 1 ? 0 : Double(Int.random(in: 0...50_000, using: &rng))
                let extraW = mode <= 1 ? 0 : Double(Int.random(in: 0...50_000, using: &rng))
                let wattsC = mode == 0 ? visWatts * 0.8 : (mode == 1 ? visWatts + 0.01 : visWatts + Double.random(in: 0...5, using: &rng))
                let d = CoalitionDelta(cpuNs: UInt64((cpuC * 1e7 * seconds).rounded(.up)),
                                       energyNJ: UInt64((wattsC * 1e9 * seconds).rounded(.up)),
                                       diskR: UInt64(((visR + extraR) * seconds).rounded(.up)),
                                       diskW: UInt64(((visW + extraW) * seconds).rounded(.up)), seconds: seconds)
                byID[cid] = (d, members.first, members)
                visCPUByID[cid] = visCPU
                visWattsByID[cid] = visWatts
                coalWatts[cid] = d.watts!
                if hidden > 0 {
                    let res = max(0, d.cpuPercent - visCPU)
                    let resDisk = max(0, d.diskReadBps! - visR) + max(0, d.diskWriteBps! - visW)
                    let resW = max(0, d.watts! - visWatts)
                    let emitted = hidden == 1 || res >= 0.5 || resW >= 0.05 || resDisk > 0
                    expectedResidualCPU[cid] = emitted ? res : 0
                    if d.cpuPercent < visCPU { clampRounds += 1 }
                    if !emitted { droppedRounds += 1 }
                }
            }
            let before = ps
            let synthetic = ca.attribute(&ps, coalitions: deltas(byID), identities: [:])
            var all = ps + synthetic

            // row level
            for (cid, _) in byID {
                let rows = all.filter { $0.coalitionID == cid }
                if let res = expectedResidualCPU[cid] {
                    let got = rows.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
                    #expect(abs(got - (visCPUByID[cid]! + res)) < 1e-6, "round \(round) cid \(cid)")
                } else {
                    #expect(rows == before.filter { $0.coalitionID == cid }, "all-visible coalition changed")
                }
            }

            // app level: Σ app CPU == Σ visible + Σ emitted residuals
            let grouped = AppGrouper.group(all, identities: [:])
            let appCPU = grouped.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
            let expectedCPU = visCPUByID.values.reduce(0, +) + expectedResidualCPU.values.reduce(0, +)
            #expect(abs(appCPU - expectedCPU) < 1e-6, "round \(round) app-level")

            // energy (v6 mode): Σ W over a restricted coalition == max(coalition W, Σ visible v6) when a residual row exists
            guard all.contains(where: { $0.provenance == .measured }) else { continue }   // no v6 value → fallback mode
            var ea = RulingEnergyAttributor()
            let watts = ea.watts(processes: all, coalitions: deltas(byID), soc: nil, dt: 1)
            for i in all.indices { all[i].energyWatts = watts[all[i].id] }
            for cid in expectedResidualCPU.keys {
                let rows = all.filter { $0.coalitionID == cid }
                let hasTarget = rows.contains { $0.provenance == .coalition }
                let got = rows.reduce(0) { $0 + ($1.energyWatts ?? 0) }
                let expected = hasTarget ? max(coalWatts[cid]!, visWattsByID[cid]!) : visWattsByID[cid]!
                #expect(abs(got - expected) < 1e-6, "round \(round) cid \(cid) energy")
            }
        }
        #expect(clampRounds > 0 && droppedRounds > 0)                // the generator hits both edge cases
    }

    // MARK: CoalitionTracker (reading → deltas)

    @Test func trackerDeltasPerCoalition() throws {
        var t = CoalitionTracker()
        let u0 = CoalitionUsage(id: 5, leaderPID: 1, memberPIDs: [1, 2], cpuTimeNs: 1 * sec, energyNJ: 100, diskReadBytes: 0, diskWriteBytes: 10)
        _ = t.deltas(.fresh(CoalitionsReading(coalitions: [u0]), capturedNs: sec))
        var u1 = u0
        u1.cpuTimeNs = 3 * sec
        u1.energyNJ = 50                                        // decreased → nil (reset), not a wrap
        u1.diskReadBytes = 4_000
        u1.diskWriteBytes = 10
        let maybe = t.deltas(.fresh(CoalitionsReading(coalitions: [u1]), capturedNs: 3 * sec))
        let d = try #require(maybe)
        let c = try #require(d.byID[5])
        #expect(c.cpuNs == 2 * sec)
        #expect(c.seconds == 2)
        #expect(c.energyNJ == nil)
        #expect(c.diskR == 4_000 && c.diskW == 0)
        #expect(d.membership[5]?.memberPIDs == [1, 2])
        #expect(t.pidToCoalition(.fresh(CoalitionsReading(coalitions: [u1]), capturedNs: 3 * sec)) == [1: 5, 2: 5])
    }

    @Test func trackerFirstSightHasNoDelta() {
        var t = CoalitionTracker()
        let d = t.deltas(.fresh(CoalitionsReading(coalitions: [CoalitionUsage(id: 5, cpuTimeNs: 1)]), capturedNs: sec))
        #expect(d?.byID.isEmpty == true)
        #expect(d?.membership[5] != nil)
        #expect(t.deltas(.notRequested) == nil)
    }
}

/// Deterministic RNG for property tests.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
