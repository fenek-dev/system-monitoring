import Foundation
import MonitorModel

/// Type-erased view of a slot (health, cost, lifecycle) for the sampling engine.
protocol AnySensorSlot: AnyObject {
    var sensorID: SensorID { get }
    var status: SensorStatus { get }
    var costNs: (last: UInt64, mean: UInt64, p95: UInt64) { get }
    func invalidate()
}

/// Owns one sensor inside the sampling engine (ARCHITECTURE §3 step 2, §6):
/// - cadence by mode (`interactive`/`background`, nil = never in background), `requires` ∩ demand, `.once`;
///   a sensor that becomes requested again runs immediately;
/// - `.fresh` when sampled, `.cached` (original `capturedNs`) when not due, `.notRequested` when not wanted;
/// - transient/timeout/posix failures reuse the last reading for ≤ 2 intervals, then nil; 3 consecutive failures →
///   `.degraded` with backoff 2 s → 60 s;
/// - unavailable/permission denied → `.unavailable`, `invalidate()`, `prepare()` retried every 5 min;
/// - crash canary from the first `prepare()`/`sample()` until the first `.fresh` (or unavailable / invalidate),
///   armed between calls only through warm-up (≤ 30 s, not degraded, still requested), then per call;
///   a marker left by a crashed launch disables the sensor.
/// All scheduling uses `ctx.uptimeNs`; `clock` only times the sensor call.
final class SensorSlot<R: Sendable & Codable>: AnySensorSlot {
    static var unavailableRetryNs: UInt64 { 300_000_000_000 }
    static var backoffStartNs: UInt64 { 2_000_000_000 }
    static var backoffMaxNs: UInt64 { 60_000_000_000 }
    /// Longest the canary stays armed between calls while a sensor warms up (N1 ruling).
    static var canaryWarmUpMaxNs: UInt64 { 30_000_000_000 }

    private let sensor: any Sensor<R>
    private let canary: CrashCanary
    private let clock: () -> UInt64

    private(set) var status: SensorStatus = .ok
    private var prepared = false
    private var armed = false
    private var armedAtNs: UInt64 = 0
    private var canaryDone = false
    /// The warm-up window ended without a real reading (degraded, no longer requested, or 30 s): from here on the
    /// canary covers each call only, as it did before S-I2.
    private var warmUpOver = false
    private var disabled = false
    private var wasRequested = false
    private var lastAttemptNs: UInt64?
    private var nextAttemptNs: UInt64 = 0
    private var backoffNs: UInt64 = 0
    private var consecutiveFailures = 0
    private var lastError: SensorError?
    private var last: (reading: R, capturedNs: UInt64, atNs: UInt64)?
    private var costs: [UInt64] = []
    private var sortedCosts: [UInt64]?
    private var costIndex = 0
    private var costSum: UInt64 = 0
    private var costCount: UInt64 = 0
    private var lastCost: UInt64 = 0

    init(_ sensor: any Sensor<R>, canary: CrashCanary) {
        self.sensor = sensor
        self.canary = canary
        self.clock = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        checkCanary()
    }

    /// Test seam: injected clock for cost measurement.
    init(_ sensor: any Sensor<R>, canary: CrashCanary, clock: @escaping () -> UInt64) {
        self.sensor = sensor
        self.canary = canary
        self.clock = clock
        checkCanary()
    }

    var sensorID: SensorID { sensor.id }

    /// Mean over the whole launch; p95 (nearest rank) over the last 100 samples, sorted lazily once per change.
    var costNs: (last: UInt64, mean: UInt64, p95: UInt64) {
        guard costCount > 0 else { return (0, 0, 0) }
        if sortedCosts == nil { sortedCosts = costs.sorted() }
        let sorted = sortedCosts!
        let rank = Int((Double(sorted.count) * 0.95).rounded(.up))
        return (lastCost, costSum / costCount, sorted[max(0, min(sorted.count, rank) - 1)])
    }

    /// Also clears a canary still armed by a warming sensor (unavailable, or a clean `stop()` at quit): the sensor's
    /// work is torn down, so a marker left behind would disable it at the next launch for nothing. A later attempt
    /// re-arms it until the first real reading.
    func invalidate() {
        if prepared { sensor.invalidate() }
        prepared = false
        disarmCanary()
        warmUpOver = false                               // a re-prepare starts new off-queue work: a new window
    }

    func sample(_ ctx: SampleContext) -> SensorResult<R> {
        if disabled { return .failed(.unavailable(CrashCanary.disabledReason), last: nil, capturedNs: nil) }
        guard let interval = interval(for: ctx) else {
            wasRequested = false
            endWarmUp()                                  // N1 (b): no longer requested
            return .notRequested
        }
        let now = ctx.uptimeNs
        if armed, now >= armedAtNs, now - armedAtNs > Self.canaryWarmUpMaxNs { endWarmUp() }   // N1 (c): 30 s cap
        let newlyRequested = !wasRequested
        wasRequested = true
        let isOnce = sensor.cadence == .once
        // `.once`: after one success it is served from cache forever (pause/resume and re-requests included).
        if isOnce, let last { return .cached(last.reading, capturedNs: last.capturedNs) }
        // Staleness and `.once` retries are measured in real ticks: never shorter than the mode's own interval.
        let tick = Self.ns(ctx.mode.interval) ?? 1_000_000_000
        let effective = isOnce ? tick : max(interval, tick)

        // Unavailable: wait for the next prepare() retry.
        if case .unavailable = status, now < nextAttemptNs {
            return .failed(lastError ?? .unavailable(status.reason ?? ""), last: nil, capturedNs: nil)
        }
        // Backoff after repeated failures.
        if consecutiveFailures > 0, now < nextAttemptNs, !newlyRequested || consecutiveFailures >= 3 {
            return failedResult(lastError ?? .timeout, now: now, window: effective)
        }
        // Not due: serve the last reading. Half a tick of slack (R2) so a jittered grid tick just short of the
        // interval counts, instead of slipping the sensor a whole tick (5 s on a 1-s grid → 6 s).
        if !isOnce, !newlyRequested, let lastAttempt = lastAttemptNs, consecutiveFailures == 0,
           now &+ tick / 2 < lastAttempt &+ interval {
            if let last { return .cached(last.reading, capturedNs: last.capturedNs) }
            return .notRequested
        }
        return attempt(now: now, retry: isOnce ? tick : interval, window: effective, ctx: ctx)
    }

    static func ns(_ d: Duration?) -> UInt64? {
        guard let parts = d?.components else { return nil }
        guard parts.seconds >= 0 else { return 0 }
        let (ns, overflow) = UInt64(parts.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? .max : ns + UInt64(parts.attoseconds / 1_000_000_000)
    }

    // MARK: - Private

    private func disarmCanary() {
        guard armed else { return }
        armed = false
        canary.disarm(sensor.id)                         // flushed (S-M7)
    }

    /// Ends the between-calls window of a warming sensor that hasn't produced a real reading (N1).
    private func endWarmUp() {
        guard !canaryDone else { return }
        warmUpOver = true
        disarmCanary()
    }

    private func checkCanary() {
        if canary.isTripped(sensor.id) {
            disabled = true
            status = .disabled(CrashCanary.disabledReason)
        }
    }

    /// Interval for the current mode in ns, or nil when the sensor is not wanted.
    private func interval(for ctx: SampleContext) -> UInt64? {
        let c = sensor.cadence
        if !c.requires.isEmpty, ctx.demand.intersection(c.requires).isEmpty { return nil }
        return Self.ns(c.interval(in: ctx.mode))
    }

    private func attempt(now: UInt64, retry: UInt64, window: UInt64, ctx: SampleContext) -> SensorResult<R> {
        lastAttemptNs = now
        // Canary (S-I2, N1): armed from the first call until the first real reading (`.fresh`), or until the sensor
        // is ruled unavailable. Between calls it stays armed only through the warm-up of an off-queue sensor
        // (`.transient`/`.timeout` "warming up": IOReport setup, HID reads, NStat callbacks), and at most 30 s — the
        // window ends on degraded, on no longer requested, or on the cap. After that it covers each call only.
        if !canaryDone, !armed {
            armed = true
            armedAtNs = now
            canary.arm(sensor.id)
        }
        if !prepared {
            do throws(SensorError) {
                try sensor.prepare()
                prepared = true
            } catch {
                return failed(error, now: now, retry: retry, window: window)
            }
        }
        let start = clock()
        let result: (reading: R, capturedNs: UInt64)
        do throws(SensorError) {
            result = try sensor.sample(ctx)
        } catch {
            recordCost(since: start)
            return failed(error, now: now, retry: retry, window: window)
        }
        canaryDone = true
        disarmCanary()
        recordCost(since: start)
        last = (result.reading, result.capturedNs, now)
        consecutiveFailures = 0
        backoffNs = 0
        lastError = nil
        status = .ok
        return .fresh(result.reading, capturedNs: result.capturedNs)
    }

    /// `fail`, then the per-call canary rule once the warm-up window is over.
    private func failed(_ error: SensorError, now: UInt64, retry: UInt64, window: UInt64) -> SensorResult<R> {
        let result = fail(error, now: now, retry: retry, window: window)
        if warmUpOver { disarmCanary() }
        return result
    }

    private func fail(_ error: SensorError, now: UInt64, retry: UInt64, window: UInt64) -> SensorResult<R> {
        lastError = error
        switch error {
        case .unavailable(let reason), .permissionDenied(let reason):
            status = .unavailable(reason)
            invalidate()                                     // also disarms: ruled unavailable, nothing left running
            last = nil
            consecutiveFailures = 0
            nextAttemptNs = now &+ Self.unavailableRetryNs
            return .failed(error, last: nil, capturedNs: nil)
        case .transient, .timeout, .posix:
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                endWarmUp()                                  // N1 (a): degraded/backoff ends the warm-up window
                status = .degraded(Self.describe(error))
                backoffNs = backoffNs == 0 ? Self.backoffStartNs : min(backoffNs * 2, Self.backoffMaxNs)
                nextAttemptNs = now &+ backoffNs
            } else {
                nextAttemptNs = now &+ retry
                if case .unavailable = status { status = .ok }       // prepare() worked on the retry
            }
            return failedResult(error, now: now, window: window)
        }
    }

    /// Last reading reused for ≤ 2 intervals (`window` = one interval, never shorter than the tick) after it was
    /// taken, then nil.
    private func failedResult(_ error: SensorError, now: UInt64, window: UInt64) -> SensorResult<R> {
        let (twice, overflow) = window.multipliedReportingOverflow(by: 2)
        if let last, now >= last.atNs, overflow || now - last.atNs <= twice {
            return .failed(error, last: last.reading, capturedNs: last.capturedNs)
        }
        return .failed(error, last: nil, capturedNs: nil)
    }

    private func recordCost(since start: UInt64) {
        let end = clock()
        let ns = end >= start ? end - start : 0
        lastCost = ns
        sortedCosts = nil
        costSum = costSum &+ ns
        costCount += 1
        if costs.count < 100 {
            costs.append(ns)
        } else {
            costs[costIndex] = ns
            costIndex = (costIndex + 1) % 100
        }
    }

    private static func describe(_ e: SensorError) -> String {
        switch e {
        case .unavailable(let s), .permissionDenied(let s), .transient(let s): s
        case .posix(let code, let ctx): "\(ctx) (errno \(code))"
        case .timeout: "Timed out"
        }
    }
}
