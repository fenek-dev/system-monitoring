import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

/// Scriptable sensor: each `sample` pops the next outcome (the last one repeats); counts calls.
final class ScriptSensor: Sensor {
    typealias Reading = Int
    let id: SensorID
    let cadence: SensorCadence
    var outcomes: [Result<Int, SensorError>]
    var prepareOutcomes: [SensorError?] = []
    var onSample: (() -> Void)?
    private(set) var prepareCount = 0, sampleCount = 0, invalidateCount = 0

    init(_ id: SensorID, cadence: SensorCadence = .everyTick, _ outcomes: [Result<Int, SensorError>]) {
        self.id = id
        self.cadence = cadence
        self.outcomes = outcomes
    }

    convenience init(cadence: SensorCadence = .everyTick, _ outcomes: [Result<Int, SensorError>]) {
        self.init(.hostCPU, cadence: cadence, outcomes)
    }

    func prepare() throws(SensorError) {
        defer { prepareCount += 1 }
        if prepareCount < prepareOutcomes.count, let e = prepareOutcomes[prepareCount] { throw e }
    }

    func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: Int, capturedNs: UInt64) {
        onSample?()
        defer { sampleCount += 1 }
        switch outcomes[min(sampleCount, outcomes.count - 1)] {
        case .success(let v): return (v, ctx.uptimeNs)
        case .failure(let e): throw e
        }
    }

    func invalidate() { invalidateCount += 1 }
}

private func ctx(_ s: Double, _ mode: SamplingMode = .interactive, demand: SamplingDemand = []) -> SampleContext {
    SampleContext(uptimeNs: UInt64(s * 1e9), mode: mode, demand: demand)
}

private func isFresh<R>(_ r: SensorResult<R>) -> Bool { if case .fresh = r { true } else { false } }
private func isCached<R>(_ r: SensorResult<R>) -> Bool { if case .cached = r { true } else { false } }
private func isNotRequested<R>(_ r: SensorResult<R>) -> Bool { if case .notRequested = r { true } else { false } }

@Suite struct SensorSlotTests {
    // MARK: cadence

    @Test func cadenceByMode() {
        let s = ScriptSensor(cadence: .every(.seconds(2), background: .seconds(10)), [.success(1)])
        let slot = SensorSlot(s, canary: .none)
        #expect(isFresh(slot.sample(ctx(0))))
        #expect(isCached(slot.sample(ctx(1))))
        #expect(slot.sample(ctx(1)).capturedNs == 0)                  // cached keeps the original capturedNs
        #expect(isFresh(slot.sample(ctx(2))))
        #expect(isCached(slot.sample(ctx(8, .background))))           // background: 10 s from the last run at 2 s
        #expect(isFresh(slot.sample(ctx(12, .background))))
        #expect(s.sampleCount == 3)
    }

    @Test func neverInBackgroundIsNotRequested() {
        let s = ScriptSensor(.temperatures, cadence: .every(.seconds(2)), [.success(1)])   // background nil
        let slot = SensorSlot(s, canary: .none)
        #expect(isFresh(slot.sample(ctx(0))))
        #expect(isNotRequested(slot.sample(ctx(5, .background))))
        #expect(s.sampleCount == 1)
    }

    @Test func pausedTakesNothing() {
        let s = ScriptSensor([.success(1)])
        let slot = SensorSlot(s, canary: .none)
        #expect(isNotRequested(slot.sample(ctx(0, .paused))))
        #expect(s.sampleCount == 0 && s.prepareCount == 0)
    }

    @Test func requiresDemandForRootMemory() {
        let s = ScriptSensor(.rootMemory, cadence: .every(.seconds(30), background: .seconds(30),
                                                          requires: [.processTable, .memoryAlert]), [.success(7)])
        let slot = SensorSlot(s, canary: .none)
        #expect(isNotRequested(slot.sample(ctx(0))))
        #expect(isFresh(slot.sample(ctx(1, demand: .processTable))))
        #expect(isCached(slot.sample(ctx(2, demand: .processTable))))
        #expect(isNotRequested(slot.sample(ctx(3))))                  // table closed → not requested
        #expect(isFresh(slot.sample(ctx(4, .background, demand: .memoryAlert))))   // re-requested → runs now
        #expect(s.sampleCount == 2)
    }

    @Test func onceCadenceSamplesOnce() {
        let s = ScriptSensor(.device, cadence: .once, [.success(1)])
        let slot = SensorSlot(s, canary: .none)
        #expect(isFresh(slot.sample(ctx(0))))
        #expect(isCached(slot.sample(ctx(100_000))))
        #expect(isCached(slot.sample(ctx(1e9, .background))))
        #expect(s.sampleCount == 1)
    }

    @Test func zeroIntervalIsEveryTick() {
        let s = ScriptSensor([.success(1)])
        let slot = SensorSlot(s, canary: .none)
        #expect(isFresh(slot.sample(ctx(0))))
        #expect(isFresh(slot.sample(ctx(0.001))))
    }

    // MARK: failures

    @Test func transientFailureReusesLastForTwoIntervalsThenNil() {
        let s = ScriptSensor(cadence: .every(.seconds(1), background: .seconds(1)),
                             [.success(5), .failure(.transient("x"))])
        let slot = SensorSlot(s, canary: .none)
        _ = slot.sample(ctx(0))
        guard case .failed(_, let last1, let cap1) = slot.sample(ctx(1)) else { Issue.record("expected failed"); return }
        #expect(last1 == 5 && cap1 == 0)
        guard case .failed(_, let last2, _) = slot.sample(ctx(2)) else { Issue.record("expected failed"); return }
        #expect(last2 == 5)
        guard case .failed(_, let last3, let cap3) = slot.sample(ctx(3)) else { Issue.record("expected failed"); return }
        #expect(last3 == nil && cap3 == nil)                           // stale → nil
    }

    @Test func threeFailuresDegradeAndBackOff() {
        let s = ScriptSensor([.failure(.posix(5, "io")), .failure(.timeout), .failure(.transient("x")),
                              .failure(.transient("x")), .success(1)])
        let slot = SensorSlot(s, canary: .none)
        _ = slot.sample(ctx(0))
        _ = slot.sample(ctx(0.1))
        #expect(slot.status == .ok)
        _ = slot.sample(ctx(0.2))
        guard case .degraded = slot.status else { Issue.record("status \(slot.status)"); return }
        _ = slot.sample(ctx(1))                                         // backoff 2 s: not attempted
        #expect(s.sampleCount == 3)
        _ = slot.sample(ctx(2.2))                                       // attempt 4 fails → backoff 4 s
        #expect(s.sampleCount == 4)
        _ = slot.sample(ctx(5))
        #expect(s.sampleCount == 4)
        #expect(isFresh(slot.sample(ctx(6.2))))                         // recovers
        #expect(slot.status == .ok)
    }

    @Test func backoffCapsAtSixtySeconds() {
        let s = ScriptSensor([.failure(.transient("x"))])
        let slot = SensorSlot(s, canary: .none)
        var t = 0.0
        for _ in 0..<20 {
            _ = slot.sample(ctx(t))
            t += 61
        }
        #expect(s.sampleCount == 20)                                    // 61 s apart: always past the cap
        let before = s.sampleCount
        _ = slot.sample(ctx(t - 61 + 59))                               // 59 s after the last attempt
        #expect(s.sampleCount == before)
    }

    @Test func unavailableInvalidatesAndRetriesPrepareEveryFiveMinutes() {
        let s = ScriptSensor([.failure(.unavailable("no SMC")), .success(3)])
        let slot = SensorSlot(s, canary: .none)
        guard case .failed(.unavailable, nil, nil) = slot.sample(ctx(0)) else { Issue.record("expected unavailable"); return }
        #expect(slot.status == .unavailable("no SMC"))
        #expect(s.invalidateCount == 1)
        _ = slot.sample(ctx(299))
        #expect(s.prepareCount == 1 && s.sampleCount == 1)
        #expect(isFresh(slot.sample(ctx(300))))
        #expect(s.prepareCount == 2)
        #expect(slot.status == .ok)
    }

    @Test func prepareFailureIsUnavailable() {
        let s = ScriptSensor([.success(1)])
        s.prepareOutcomes = [.permissionDenied("EPERM")]
        let slot = SensorSlot(s, canary: .none)
        _ = slot.sample(ctx(0))
        #expect(slot.status == .unavailable("EPERM"))
        #expect(s.sampleCount == 0)
        #expect(isFresh(slot.sample(ctx(300))))
    }

    // MARK: canary

    @Test func trippedCanaryDisablesSensor() {
        let canary = CrashCanary.inMemory()
        canary.arm(.smc)                                                // left over from a crashed launch
        let s = ScriptSensor(.smc, [.success(1)])
        let slot = SensorSlot(s, canary: canary)
        #expect(slot.status == .disabled("Disabled after a crash"))
        guard case .failed = slot.sample(ctx(0)) else { Issue.record("expected failed"); return }
        #expect(s.prepareCount == 0 && s.sampleCount == 0)
        canary.reenableAll()
        #expect(!canary.isTripped(.smc))
    }

    @Test func canaryArmedDuringFirstCallsOnly() {
        let canary = CrashCanary.inMemory()
        let s = ScriptSensor(.smc, [.success(1)])
        var seen: [Bool] = []
        s.onSample = { seen.append(canary.isTripped(.smc)) }
        let slot = SensorSlot(s, canary: canary)
        _ = slot.sample(ctx(0))
        _ = slot.sample(ctx(1))
        #expect(seen == [true, false])
        #expect(!canary.isTripped(.smc))
    }

    @Test func userDefaultsCanaryRoundTrip() {
        let suite = "dev.telltale.tests.\(UUID().uuidString)"
        let canary = CrashCanary.defaults(suite: suite)
        canary.arm(.gpuClients)
        #expect(CrashCanary.defaults(suite: suite).isTripped(.gpuClients))
        canary.reenableAll()
        #expect(!canary.isTripped(.gpuClients))
        UserDefaults().removePersistentDomain(forName: suite)
    }

    // MARK: cost

    @Test func costStatistics() {
        var now: UInt64 = 0
        let s = ScriptSensor([.success(1)])
        s.onSample = { now += 1_000 }
        let slot = SensorSlot(s, canary: .none, clock: { now })
        for i in 0..<10 { _ = slot.sample(ctx(Double(i))) }
        #expect(slot.costNs.last == 1_000)
        #expect(slot.costNs.mean == 1_000)
        #expect(slot.costNs.p95 == 1_000)
    }
}
