import Foundation
import os
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// `.offCooperativePool`: the box tests block their thread by design (`sample(firstWait:)`, `waitIdle`). On
/// cooperative-pool threads that starves the process: once all ncpu cooperative threads are blocked, the kernel
/// admits no non-overcommit GCD threads, so the box's `.utility` concurrent run queue stalls until a waiter times out.
@Suite(.serialized, .offCooperativePool) struct RootMemoryParseTests {
    @Test func parsesPidAndRSSKilobytesToBytes() {
        let out = "    1  12640\n  418 6086432\n99999      0\n"
        #expect(RootMemoryParser.parse(out) == [1: 12_640 * 1024, 418: 6_086_432 * 1024, 99_999: 0])
    }

    @Test func skipsMalformedLines() {
        let out = """
          PID    RSS
        abc 12
        12
        13 x
        -5 100
        14 -1
        15 20 extra
            \t
        16\t32
        17 18446744073709551615
        """
        #expect(RootMemoryParser.parse(out) == [16: 32 * 1024])
    }

    @Test func emptyOutputIsEmpty() {
        #expect(RootMemoryParser.parse("").isEmpty)
    }

    @Test func duplicatePidKeepsLast() {
        #expect(RootMemoryParser.parse("7 1\n7 2\n") == [7: 2048])
    }

    /// `ps -axo pid=,rss=` captured on this Mac.
    @Test func capturedPsOutputParses() throws {
        let text = try W6aFixture.string("ps_rss.txt")
        let lines = text.split(separator: "\n").count
        let parsed = RootMemoryParser.parse(text)
        #expect(parsed.count == lines)
        #expect(parsed[1] != nil)                       // launchd (root) is covered
        #expect(parsed.values.contains { $0 > 100 << 20 })
    }

    // MARK: async box (fake runner)

    @Test func garbageOutputIsTransientButBlankIsEmpty() throws {
        #expect(throws: SensorError.transient("ps output had no parseable pid/rss lines")) {
            try RootMemoryParser.reading("ps: illegal option\nusage: ps …\n")
        }
        #expect(try RootMemoryParser.reading(" \n").rssByPID.isEmpty)
    }

    /// Runs on dedicated threads: the box's `.utility` concurrent queue can wait hundreds of ms for a thread while
    /// other suites keep the cooperative pool busy, which the 20–250 ms waits below would report as box failures.
    static func box(_ runner: @escaping RootMemoryBox.Runner, deadline: Duration = .seconds(2)) -> RootMemoryBox {
        RootMemoryBox(runner: runner, deadline: deadline, spawn: TestSpawn.dedicatedThread)
    }

    @Test func firstSampleWaitsForTheFirstRun() throws {
        let box = Self.box { _ in "1 4\n2 8\n" }
        let (r, captured) = try box.sample(firstWait: .milliseconds(250))
        #expect(r.rssByPID == [1: 4096, 2: 8192])
        #expect(captured > 0)
    }

    @Test func laterSamplesReturnLastResultAndStartNextRun() throws {
        let counter = Counter()
        let box = Self.box { _ in "1 \(counter.next())\n" }
        let first = try box.sample(firstWait: .milliseconds(250))
        #expect(first.reading.rssByPID[1] == 1024)
        #expect(box.waitIdle(timeout: .seconds(2)))
        #expect(counter.value == 1)                                  // the first sample started exactly one run
        let second = try box.sample(firstWait: .milliseconds(250))   // last completed (run 1), starts run 2
        #expect(second.reading.rssByPID[1] == 1024)
        #expect(second.capturedNs == first.capturedNs)
        #expect(box.waitIdle(timeout: .seconds(2)))
        let third = try box.sample(firstWait: .milliseconds(250))    // run 2
        #expect(third.reading.rssByPID[1] == 2048)
        #expect(third.capturedNs > first.capturedNs)
        #expect(box.waitIdle(timeout: .seconds(2)))
        #expect(counter.value == 3)
    }

    @Test func runnerFailureIsThrownOnce() throws {
        let box = Self.box { _ in throw SensorError.transient("ps exited with status 1") }
        #expect(throws: SensorError.transient("ps exited with status 1")) { try box.sample(firstWait: .milliseconds(250)) }
    }

    @Test func slowFirstRunTimesOut() throws {
        let box = Self.box { _ in Thread.sleep(forTimeInterval: 0.3); return "1 1\n" }
        #expect(throws: SensorError.timeout) { try box.sample(firstWait: .milliseconds(20)) }
        #expect(box.waitIdle(timeout: .seconds(2)))
        #expect(try box.sample(firstWait: .milliseconds(20)).reading.rssByPID == [1: 1024])
    }

    /// Review fix: only the very first call waits; a call during an in-flight run returns at once.
    @Test func callDuringInFlightRunDoesNotBlock() throws {
        let box = Self.box { _ in Thread.sleep(forTimeInterval: 0.3); return "1 1\n" }
        #expect(throws: SensorError.timeout) { try box.sample(firstWait: .milliseconds(20)) }
        let t0 = ContinuousClock.now
        #expect(throws: SensorError.transient("ps result pending")) { try box.sample(firstWait: .milliseconds(250)) }
        #expect(ContinuousClock.now - t0 < .milliseconds(5))
        #expect(box.waitIdle(timeout: .seconds(2)))
    }

    /// Review fix: a hung run is cancelled at its deadline, fails with `.timeout`, and the next run can start.
    @Test func hungRunIsCancelledAtDeadline() throws {
        let cancelled = Counter()
        let box = Self.box({ token in
            let done = DispatchSemaphore(value: 0)
            token.onCancel { _ = cancelled.next(); done.signal() }
            done.wait()                                   // hangs until cancelled
            throw SensorError.transient("killed")
        }, deadline: .milliseconds(100))
        #expect(throws: SensorError.timeout) { try box.sample(firstWait: .milliseconds(1_000)) }
        #expect(cancelled.value == 1)
        #expect(box.runsStarted == 1)
        #expect(throws: SensorError.transient("ps result pending")) { try box.sample(firstWait: .milliseconds(1)) }
        #expect(box.runsStarted == 2)                     // not stuck behind the hung run
        #expect(box.waitIdle(timeout: .seconds(2)))
        #expect(cancelled.value == 2)
    }

    @Test func resetForgetsLastReading() throws {
        let box = Self.box { _ in "1 1\n" }
        _ = try box.sample(firstWait: .milliseconds(250))
        #expect(box.waitIdle(timeout: .seconds(2)))
        box.reset()
        let r = try box.sample(firstWait: .milliseconds(250))   // waits again for a fresh run
        #expect(r.reading.rssByPID == [1: 1024])
        #expect(box.runsStarted >= 2)
    }

    @Test func cadenceIsThirtySecondsGatedOnDemand() {
        let s = RootMemorySensor()
        #expect(s.cadence == .every(.seconds(30), background: .seconds(30), requires: [.processTable, .memoryAlert]))
        #expect(s.id == .rootMemory)
    }

    final class Counter: Sendable {
        private let n = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { n.withLock { $0 } }
        func next() -> Int { n.withLock { $0 += 1; return $0 } }
    }
}
