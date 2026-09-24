import Dispatch
import Foundation
import MonitorModel
import os

// MARK: - Parse layer (pure)

enum RootMemoryParser {
    /// `ps -axo pid=,rss=` → pid: bytes (RSS is KiB). Lines that are not exactly `<pid ≥ 0> <rss>` are skipped.
    static func parse(_ text: String) -> [Int32: UInt64] {
        var out: [Int32: UInt64] = [:]
        out.reserveCapacity(1024)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count == 2, let pid = Int32(f[0]), pid >= 0, let kb = UInt64(f[1]) else { continue }
            let (bytes, overflow) = kb.multipliedReportingOverflow(by: 1024)
            guard !overflow else { continue }
            out[pid] = bytes
        }
        return out
    }

    /// Parsed reading, or `.transient` when non-blank output has no parseable line (format changed / garbage).
    static func reading(_ text: String) throws(SensorError) -> RootMemoryReading {
        let rss = parse(text)
        if rss.isEmpty, text.contains(where: { !$0.isWhitespace }) {
            throw SensorError.transient("ps output had no parseable pid/rss lines")
        }
        return RootMemoryReading(rssByPID: rss)
    }
}

// MARK: - Async box

/// Cancellation handle handed to a run; the box cancels it when the run's deadline passes.
final class RunCancellation: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var handler: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Registers the cancel action; runs it at once if already cancelled.
    func onCancel(_ handler: @escaping @Sendable () -> Void) {
        let runNow = state.withLock { s -> Bool in
            if s.cancelled { return true }
            s.handler = handler
            return false
        }
        if runNow { handler() }
    }

    func cancel() {
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            guard !s.cancelled else { return nil }
            s.cancelled = true
            defer { s.handler = nil }
            return s.handler
        }
        handler?()
    }
}

/// Runs `ps` off the sampler queue. `sample` returns the last completed result and starts the next run.
/// Only the very first call ever waits (≤ `firstWait`); later calls never block. Each run has a deadline:
/// on expiry the run fails with `.timeout`, is cancelled (live runner: SIGTERM, then SIGKILL), and the box
/// is free to start the next run. State lives behind an unfair lock; the box is `Sendable`.
final class RootMemoryBox: Sendable {
    typealias Runner = @Sendable (RunCancellation) throws -> String

    private struct State: Sendable {
        var last: RootMemoryReading?
        var lastCapturedNs: UInt64 = 0
        var pendingError: SensorError?
        var current: RunCancellation?
        var generation: UInt64 = 0
        var waitedOnce = false
        var runsStarted = 0
    }

    /// Starts a run's work somewhere off the caller. Test seam only: the default is the `.utility` concurrent run
    /// queue; tests pass dedicated threads, because a non-overcommit queue gets no thread while other suites keep
    /// the cooperative pool busy, and the box's timing tests would measure that instead of the box.
    typealias Spawn = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let spawn: Spawn
    private let deadlineQueue = DispatchQueue(label: "dev.telltale.sensors.rootMemory.deadline", qos: .utility)
    private let inflight = DispatchGroup()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let runner: Runner
    private let deadline: Duration

    init(runner: @escaping Runner, deadline: Duration = .seconds(2), spawn: Spawn? = nil) {
        self.runner = runner
        self.deadline = deadline
        let runQueue = DispatchQueue(label: "dev.telltale.sensors.rootMemory", qos: .utility, attributes: .concurrent)
        self.spawn = spawn ?? { runQueue.async(execute: $0) }
    }

    var runsStarted: Int { state.withLock { $0.runsStarted } }

    func sample(firstWait: Duration) throws(SensorError) -> (reading: RootMemoryReading, capturedNs: UInt64) {
        if let result = try takeCompleted() {
            startIfIdle()
            return result
        }
        let first = state.withLock { s -> Bool in
            defer { s.waitedOnce = true }
            return !s.waitedOnce
        }
        startIfIdle()
        guard first else { throw SensorError.transient("ps result pending") }
        guard inflight.wait(timeout: .now() + .nanoseconds(Self.ns(firstWait))) == .success else {
            throw SensorError.timeout
        }
        if let result = try takeCompleted() { return result }
        throw SensorError.transient("ps produced no result")
    }

    /// Waits until no run is in flight; false on timeout (tests).
    @discardableResult
    func waitIdle(timeout: Duration = .seconds(5)) -> Bool {
        inflight.wait(timeout: .now() + .nanoseconds(Self.ns(timeout))) == .success
    }

    /// Forget results (no hours-old RSS after a resume); the next call waits once again.
    func reset() {
        state.withLock { s in
            s.last = nil
            s.pendingError = nil
            s.waitedOnce = false
        }
    }

    /// Throws (and clears) a failure newer than the last success; else the last success, if any.
    private func takeCompleted() throws(SensorError) -> (reading: RootMemoryReading, capturedNs: UInt64)? {
        let (reading, captured, error) = state.withLock { s -> (RootMemoryReading?, UInt64, SensorError?) in
            if let e = s.pendingError {
                s.pendingError = nil
                return (nil, 0, e)
            }
            return (s.last, s.lastCapturedNs, nil)
        }
        if let error { throw error }
        return reading.map { ($0, captured) }
    }

    private func startIfIdle() {
        let token = RunCancellation()
        let gen = state.withLock { s -> UInt64? in
            guard s.current == nil else { return nil }
            s.current = token
            s.generation += 1
            s.runsStarted += 1
            return s.generation
        }
        guard let gen else { return }
        inflight.enter()
        deadlineQueue.asyncAfter(deadline: .now() + .nanoseconds(Self.ns(deadline))) { [self] in
            guard claim(gen, .failure(.timeout)) else { return }
            token.cancel()          // before leave(): a waiter sees the kill already requested
            inflight.leave()
        }
        let runner = self.runner
        spawn { [self] in
            let outcome: Result<RootMemoryReading, SensorError>
            do {
                outcome = .success(try RootMemoryParser.reading(try runner(token)))
            } catch let e as SensorError {
                outcome = .failure(e)
            } catch {
                outcome = .failure(.transient("ps: \(error)"))
            }
            if claim(gen, outcome) { inflight.leave() }
        }
    }

    /// Records the first outcome of run `gen` (completion or deadline) and returns true; later ones are dropped.
    /// The caller that claimed leaves `inflight`.
    private func claim(_ gen: UInt64, _ outcome: Result<RootMemoryReading, SensorError>) -> Bool {
        let captured = w6aUptimeNs()
        let first = state.withLock { s -> Bool in
            guard s.generation == gen, s.current != nil else { return false }
            s.current = nil
            switch outcome {
            case .success(let r):
                s.last = r
                s.lastCapturedNs = captured
                s.pendingError = nil
            case .failure(let e):
                s.pendingError = e
            }
            return true
        }
        return first
    }

    private static func ns(_ d: Duration) -> Int {
        let c = d.components
        return Int(clamping: c.seconds &* 1_000_000_000 &+ c.attoseconds / 1_000_000_000)
    }
}

// MARK: - FFI layer

enum RootMemoryFFI {
    static let psPath = "/bin/ps"

    /// setuid-root `/bin/ps` sees every pid (~20 ms per run, findings/sysmon.md). On cancellation: SIGTERM,
    /// then SIGKILL after 0.5 s.
    static func runPS(_ cancel: RunCancellation) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: psPath)
        p.arguments = ["-axo", "pid=,rss="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // S-M3: the pid is signalled only while ps has not terminated, re-checked under the lock the termination
        // handler also takes — so a kill can't race Foundation reaping ps and hit a reused pid.
        let exited = OSAllocatedUnfairLock(initialState: false)
        p.terminationHandler = { _ in exited.withLock { $0 = true } }
        do { try p.run() } catch { throw SensorError.unavailable("\(psPath): \(error.localizedDescription)") }
        let pid = p.processIdentifier
        let signal: @Sendable (Int32) -> Void = { sig in
            exited.withLock { done in
                if !done && p.isRunning { kill(pid, sig) }
            }
        }
        cancel.onCancel {
            signal(SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(500)) { signal(SIGKILL) }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        exited.withLock { $0 = true }
        if p.terminationReason == .uncaughtSignal {
            if cancel.isCancelled { throw SensorError.timeout }
            throw SensorError.transient("\(psPath) killed by signal \(p.terminationStatus)")
        }
        guard p.terminationStatus == 0 else {
            throw SensorError.transient("\(psPath) exited with status \(p.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Sensor

/// RSS for every pid (incl. root/foreign-uid, where rusage is denied) from setuid `/bin/ps`, off the sampler queue.
/// Only while a process table is visible or a memory alert is active (ARCHITECTURE §10).
public final class RootMemorySensor: Sensor {
    public typealias Reading = RootMemoryReading
    public let id = SensorID.rootMemory
    public let cadence = SensorCadence.every(.seconds(30), background: .seconds(30), requires: [.processTable, .memoryAlert])

    private let box: RootMemoryBox

    public convenience init() { self.init(runner: RootMemoryFFI.runPS) }

    init(runner: @escaping RootMemoryBox.Runner) { box = RootMemoryBox(runner: runner) }

    public func prepare() throws(SensorError) {
        guard FileManager.default.isExecutableFile(atPath: RootMemoryFFI.psPath) else {
            throw SensorError.unavailable("\(RootMemoryFFI.psPath) is not available")
        }
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: RootMemoryReading, capturedNs: UInt64) {
        try box.sample(firstWait: .milliseconds(250))
    }

    public func invalidate() { box.reset() }
}
