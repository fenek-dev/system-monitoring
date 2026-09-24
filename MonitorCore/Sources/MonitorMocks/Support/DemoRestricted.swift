import Foundation
import MonitorModel

/// Synthetic restricted/coalition rows for the `.restricted` scenario (ARCHITECTURE §5.1 point 5,
/// §3.12 grouping rules 3–4): ~330 root-owned rows without a readable responsible PID, most of which
/// stay `.restricted` ("—" for CPU/energy, counted in their coalition's residual), plus a handful of
/// coalitions with exactly one restricted member (promoted to `.coalition`, real estimated values) and
/// several coalitions with many restricted members (one synthetic `ProcessID.coalitionResidual` row each).
enum DemoRestricted {
    private static let daemonStems = [
        "com.apple.suggestd", "com.apple.corespotlightd", "com.apple.diagnosticd", "com.apple.cfprefsd",
        "com.apple.powerd", "com.apple.locationd", "com.apple.trustd", "com.apple.secinitd",
        "com.apple.audio.midiserver", "com.apple.mobileassetd", "com.apple.wifianalyticsd",
        "com.apple.usernoted", "com.apple.rapportd", "com.apple.homed", "com.apple.familycircled",
        "com.apple.parsecd", "com.apple.symptomsd", "com.apple.awdd", "com.apple.biomed", "com.apple.contactsd",
    ]

    /// Deterministic in `seed` and `tick` (jitter only, not row count/composition, so table sizes stay stable
    /// across ticks — matching how a real process table only gains/loses rows on process start/exit).
    static func processes(seed: UInt64, tick: Int, restrictedRowTarget: Int = 330) -> [ProcessSample] {
        var rng = DemoLCG(seed: UInt32(truncatingIfNeeded: seed &+ 777))
        var nextPID: Int32 = 3_000
        func pid() -> Int32 { defer { nextPID += 1 }; return nextPID }
        let jitter = 1.0 + 0.05 * sin(Double(tick) * 0.3)

        var out: [ProcessSample] = []

        // Coalitions with exactly one restricted member: promoted to `.coalition`, real (estimated) values.
        let singletons = 3
        for i in 0..<singletons {
            let leader = daemonStems[i % daemonStems.count]
            let coalitionID = UInt64(9_000 + i)
            let cpu = (0.1 + rng.next() * 1.8) * jitter
            out.append(ProcessSample(
                id: ProcessID(pid: pid(), startTimeUs: 1), name: leader, path: nil, user: "root", uid: 0,
                isCurrentUser: false, app: AppKey(kind: .process, id: leader), provenance: .coalition, coalitionID: coalitionID,
                coalitionLeaderName: leader, cpuPercent: cpu, cpuTimeNs: 3_600 * 1_000_000_000, threads: 2,
                memory: UInt64(4 + Int(rng.next() * 40)) * 1_048_576, memorySource: .rss(ageNs: 2_000_000_000),
                energyWatts: 0.02 + rng.next() * 0.1, energyEstimated: true
            ))
        }

        // Coalitions with many restricted members; one synthetic residual row each.
        let groupCoalitions = 5
        var remaining = max(0, restrictedRowTarget)
        for g in 0..<groupCoalitions {
            let leader = daemonStems[(singletons + g) % daemonStems.count]
            let coalitionID = UInt64(9_100 + g)
            let isLast = g == groupCoalitions - 1
            let membersInGroup = isLast ? remaining : max(10, remaining / (groupCoalitions - g))
            remaining -= membersInGroup
            for _ in 0..<membersInGroup {
                out.append(ProcessSample(
                    id: ProcessID(pid: pid(), startTimeUs: 1), name: leader, path: nil, user: "root", uid: 0,
                    isCurrentUser: false, app: AppKey(kind: .process, id: leader), provenance: .restricted,
                    coalitionID: coalitionID, coalitionLeaderName: leader, threads: 1
                ))
            }
            let residualCPU = (0.3 + rng.next() * 3.0) * jitter
            out.append(ProcessSample(
                id: .coalitionResidual(coalitionID), name: leader, path: nil, user: "root", uid: 0,
                isCurrentUser: false, app: AppKey(kind: .process, id: leader), provenance: .coalition, coalitionID: coalitionID,
                coalitionLeaderName: leader, cpuPercent: residualCPU, cpuTimeNs: 1_800 * 1_000_000_000,
                memory: UInt64(20 + Int(rng.next() * 200)) * 1_048_576, memorySource: .rss(ageNs: 2_000_000_000),
                energyWatts: 0.05 + rng.next() * 0.3, energyEstimated: true
            ))
        }
        return out
    }
}
