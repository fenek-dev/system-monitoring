import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Hardware smoke: opt-in, run one suite at a time at checkpoints; never in parallel with other suites or builds
/// (load-sensitive). `TELLTALE_HW_TESTS=1 swift test --no-parallel --filter AssertionSmokeTests`.
@Suite(.enabled(if: W6aFixture.hardwareTests), .serialized, .offCooperativePool)
struct AssertionSmokeTests {
    /// Independent of the implementation's tables: IOPMLib.h sleep-preventing types incl. legacy names.
    static let preventingPmsetTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion",
    ]

    /// Plist-safe copy: pid keys as strings, only plist value types kept.
    static func plistSafe(_ raw: [AnyHashable: Any]) -> [String: [[String: Any]]] {
        var out: [String: [[String: Any]]] = [:]
        for (k, v) in raw {
            guard let list = v as? [[String: Any]] else { continue }
            out["\(k.base)"] = list.map { a in
                a.filter { $0.value is String || $0.value is NSNumber || $0.value is Date || $0.value is Data }
            }
        }
        return out
    }

    @Test func captureFixture() throws {
        guard W6aFixture.capture else { return }
        let raw = try SleepAssertionFFI.copyByProcess()
        let data = try PropertyListSerialization.data(fromPropertyList: Self.plistSafe(raw), format: .xml, options: 0)
        try data.write(to: W6aFixture.sourceURL("assertions.plist"))
        if let a = raw.values.compactMap({ ($0 as? [[String: Any]])?.first }).first {
            print("W6a assertion keys: \(a.keys.sorted())")
        }
    }

    @Test func matchesPmset() throws {
        let t = w6aUptimeNs()
        let r = try SleepAssertionSensor().sample(SampleContext()).reading
        let cost = w6aUptimeNs() - t
        let pm = try W6aFixture.run(["/usr/bin/pmset", "-g", "assertions"])
        // Expected pids from pmset: the owner of a preventing assertion (legacy names included), or its
        // "Created for PID" beneficiary when the next line names one.
        var expected = Set<Int32>()
        var pending: Int32?          // owner of the previous preventing line, not yet resolved
        func resolvePending() { if let p = pending { expected.insert(p) }; pending = nil }
        for line in pm.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Created for PID:") {
                if pending != nil,
                   let pid = Int32(s.dropFirst("Created for PID:".count).trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) {
                    expected.insert(pid)
                    pending = nil
                }
                continue
            }
            if s.hasPrefix("Resources:") { continue }
            resolvePending()
            guard s.hasPrefix("pid "), let pid = Int32(s.dropFirst(4).prefix { $0.isNumber }) else { continue }
            // "pid N(name with spaces): [0x…] HH:MM:SS Type named: …"
            let afterID = s.split(separator: "]", maxSplits: 1).dropFirst().first ?? ""
            let type = afterID.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if Self.preventingPmsetTypes.contains(type) { pending = pid }
        }
        resolvePending()
        let ours = Set(r.byPID.keys)
        print("W6a assertions: ours=\(r.byPID.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.joined(separator: ","))" }) " +
              "pmset=\(expected.sorted()) cost=\(W6aFixture.ms(cost))ms")
        #expect(ours == expected)
    }
}
