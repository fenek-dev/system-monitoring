import Foundation
import os
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct RootMemoryParseTests {
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

    @Test func firstSampleWaitsForTheFirstRun() throws {
        let box = RootMemoryBox(runner: { "1 4\n2 8\n" })
        let (r, captured) = try box.sample(firstWait: .milliseconds(250))
        #expect(r.rssByPID == [1: 4096, 2: 8192])
        #expect(captured > 0)
    }

    @Test func laterSamplesReturnLastResultAndStartNextRun() throws {
        let counter = Counter()
        let box = RootMemoryBox(runner: { "1 \(counter.next())\n" })
        let first = try box.sample(firstWait: .milliseconds(250))
        #expect(first.reading.rssByPID[1] == 1024)
        box.waitIdle()
        #expect(counter.value == 1)                                  // the first sample started exactly one run
        let second = try box.sample(firstWait: .milliseconds(250))   // last completed (run 1), starts run 2
        #expect(second.reading.rssByPID[1] == 1024)
        #expect(second.capturedNs == first.capturedNs)
        box.waitIdle()
        let third = try box.sample(firstWait: .milliseconds(250))    // run 2
        #expect(third.reading.rssByPID[1] == 2048)
        #expect(third.capturedNs > first.capturedNs)
        box.waitIdle()
        #expect(counter.value == 3)
    }

    @Test func runnerFailureIsThrownOnce() throws {
        let box = RootMemoryBox(runner: { throw SensorError.posix(5, "ps") })
        #expect(throws: SensorError.posix(5, "ps")) { try box.sample(firstWait: .milliseconds(250)) }
    }

    @Test func slowFirstRunTimesOut() throws {
        let box = RootMemoryBox(runner: { Thread.sleep(forTimeInterval: 0.3); return "1 1\n" })
        #expect(throws: SensorError.timeout) { try box.sample(firstWait: .milliseconds(20)) }
        box.waitIdle()
        #expect(try box.sample(firstWait: .milliseconds(20)).reading.rssByPID == [1: 1024])
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
