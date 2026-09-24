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
/// - crash canary around the first `prepare()`/`sample()`; a marker left by a crashed launch disables the sensor.
/// All scheduling uses `ctx.uptimeNs`; `clock` only times the sensor call.
final class SensorSlot<R: Sendable & Codable>: AnySensorSlot {
    static var unavailableRetryNs: UInt64 { 300_000_000_000 }
    static var backoffStartNs: UInt64 { 2_000_000_000 }
    static var backoffMaxNs: UInt64 { 60_000_000_000 }

    private let sensor: any Sensor<R>
    private let canary: CrashCanary
    private let clock: () -> UInt64

    private(set) var status: SensorStatus = .ok
    private var prepared = false
    private var armed = false
    private var canaryDone = false
    private var disabled = false
    private var wasRequested = false
    private var lastAttemptNs: UInt64?
    private var nextAttemptNs: UInt64 = 0
    private var backoffNs: UInt64 = 0
    private var consecutiveFailures = 0
    private var lastError: SensorError?
    private var last: (reading: R, capturedNs: UInt64, atNs: UInt64)?
    private var costs: [UInt64] = []
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

    var costNs: (last: UInt64, mean: UInt64, p95: UInt64) {
        guard costCount > 0 else { return (0, 0, 0) }
        let sorted = costs.sorted()
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        return (lastCost, costSum / costCount, p95)
    }

    func invalidate() {
        if prepared { sensor.invalidate() }
        prepared = false
    }

    func sample(_ ctx: SampleContext) -> SensorResult<R> {
        if disabled { return .failed(.unavailable(CrashCanary.disabledReason), last: nil, capturedNs: nil) }
        guard let interval = interval(for: ctx) else {
            wasRequested = false
            return .notRequested
        }
        let now = ctx.uptimeNs
        let newlyRequested = !wasRequested
        wasRequested = true

        // Unavailable: wait for the next prepare() retry.
        if case .unavailable = status, now < nextAttemptNs {
            return .failed(lastError ?? .unavailable(status.reason ?? ""), last: nil, capturedNs: nil)
        }
        // Backoff after repeated failures.
        if consecutiveFailures > 0, now < nextAttemptNs, !newlyRequested || consecutiveFailures >= 3 {
            return failedResult(lastError ?? .timeout, now: now, interval: interval)
        }
        // Not due: serve the last reading.
        if !newlyRequested, let lastAttempt = lastAttemptNs, consecutiveFailures == 0 {
            let due = sensor.cadence == .once ? last == nil : now >= lastAttempt &+ interval
            if !due {
                if let last { return .cached(last.reading, capturedNs: last.capturedNs) }
                return .notRequested
            }
        }
        return attempt(now: now, interval: interval, ctx: ctx)
    }

    // MARK: - Private

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
        let d: Duration? = switch ctx.mode {
        case .interactive: c.interactive
        case .background: c.background
        case .paused: nil
        }
        guard let d else { return nil }
        let parts = d.components
        guard parts.seconds >= 0 else { return 0 }
        let (ns, overflow) = UInt64(parts.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? .max : ns + UInt64(parts.attoseconds / 1_000_000_000)
    }

    private func attempt(now: UInt64, interval: UInt64, ctx: SampleContext) -> SensorResult<R> {
        lastAttemptNs = now
        if !canaryDone {                              // first prepare()/sample() of this launch
            canaryDone = true
            armed = true
            canary.arm(sensor.id)
        }
        defer {
            if armed {
                armed = false
                canary.disarm(sensor.id)
            }
        }
        if !prepared {
            do throws(SensorError) {
                try sensor.prepare()
                prepared = true
            } catch {
                return fail(error, now: now, interval: interval)
            }
        }
        let start = clock()
        let result: (reading: R, capturedNs: UInt64)
        do throws(SensorError) {
            result = try sensor.sample(ctx)
        } catch {
            recordCost(since: start)
            return fail(error, now: now, interval: interval)
        }
        recordCost(since: start)
        last = (result.reading, result.capturedNs, now)
        consecutiveFailures = 0
        backoffNs = 0
        lastError = nil
        status = .ok
        return .fresh(result.reading, capturedNs: result.capturedNs)
    }

    private func fail(_ error: SensorError, now: UInt64, interval: UInt64) -> SensorResult<R> {
        lastError = error
        switch error {
        case .unavailable(let reason), .permissionDenied(let reason):
            status = .unavailable(reason)
            invalidate()
            last = nil
            consecutiveFailures = 0
            nextAttemptNs = now &+ Self.unavailableRetryNs
            return .failed(error, last: nil, capturedNs: nil)
        case .transient, .timeout, .posix:
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                status = .degraded(Self.describe(error))
                backoffNs = backoffNs == 0 ? Self.backoffStartNs : min(backoffNs * 2, Self.backoffMaxNs)
                nextAttemptNs = now &+ backoffNs
            } else {
                nextAttemptNs = now &+ interval
            }
            return failedResult(error, now: now, interval: interval)
        }
    }

    /// Last reading reused for ≤ 2 intervals after it was taken, then nil.
    private func failedResult(_ error: SensorError, now: UInt64, interval: UInt64) -> SensorResult<R> {
        let window = 2 * max(interval, 1_000_000_000)
        if let last, now >= last.atNs, now - last.atNs <= window {
            return .failed(error, last: last.reading, capturedNs: last.capturedNs)
        }
        return .failed(error, last: nil, capturedNs: nil)
    }

    private func recordCost(since start: UInt64) {
        let end = clock()
        let ns = end >= start ? end - start : 0
        lastCost = ns
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
