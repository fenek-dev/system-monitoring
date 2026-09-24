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
}

// MARK: - Async box

/// Runs `ps` on its own queue. `sample` returns the last completed result and starts the next run; the very first
/// call waits (≤ `firstWait`) for its run. State lives behind an unfair lock; the box is `Sendable`.
final class RootMemoryBox: Sendable {
    typealias Runner = @Sendable () throws -> String

    private struct State: Sendable {
        var last: RootMemoryReading?
        var lastCapturedNs: UInt64 = 0
        var pendingError: SensorError?
        var running = false
    }

    private let queue = DispatchQueue(label: "dev.telltale.sensors.rootMemory", qos: .utility)
    private let inflight = DispatchGroup()
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let runner: Runner

    init(runner: @escaping Runner) { self.runner = runner }

    func sample(firstWait: Duration) throws(SensorError) -> (reading: RootMemoryReading, capturedNs: UInt64) {
        if let result = try takeCompleted() {
            startIfIdle()
            return result
        }
        startIfIdle()
        let ms = Int(firstWait.components.seconds * 1000 + firstWait.components.attoseconds / 1_000_000_000_000_000)
        guard inflight.wait(timeout: .now() + .milliseconds(ms)) == .success else { throw SensorError.timeout }
        if let result = try takeCompleted() { return result }
        throw SensorError.transient("ps produced no result")
    }

    /// Blocks until no run is in flight (tests).
    func waitIdle() { inflight.wait() }

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
        let start = state.withLock { s -> Bool in
            guard !s.running else { return false }
            s.running = true
            return true
        }
        guard start else { return }
        inflight.enter()
        queue.async { [self] in
            let outcome: Result<RootMemoryReading, SensorError>
            do {
                outcome = .success(RootMemoryReading(rssByPID: RootMemoryParser.parse(try runner())))
            } catch let e as SensorError {
                outcome = .failure(e)
            } catch {
                outcome = .failure(.transient("ps: \(error)"))
            }
            let captured = w6aUptimeNs()
            state.withLock { s in
                s.running = false
                switch outcome {
                case .success(let r):
                    s.last = r
                    s.lastCapturedNs = captured
                    s.pendingError = nil
                case .failure(let e):
                    s.pendingError = e
                }
            }
            inflight.leave()
        }
    }
}

// MARK: - FFI layer

enum RootMemoryFFI {
    static let psPath = "/bin/ps"

    /// setuid-root `/bin/ps` sees every pid (~20 ms per run, findings/sysmon.md).
    static func runPS() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: psPath)
        p.arguments = ["-axo", "pid=,rss="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw SensorError.unavailable("\(psPath): \(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationReason == .exit, p.terminationStatus == 0 else {
            throw SensorError.posix(p.terminationStatus, "\(psPath) exited abnormally")
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

    public func invalidate() {}
}
