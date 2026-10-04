import Foundation
import Testing
@testable import MonitorDiskTools

@Suite struct ClassifierProcessTests {
    private static func timed<T>(_ body: () throws -> T) rethrows -> (T, TimeInterval) {
        let start = Date()
        let value = try body()
        return (value, Date().timeIntervalSince(start))
    }

    /// Bug caught: a probe that ignores SIGTERM hangs the classifier forever.
    @Test func childIgnoringSigtermIsKilled() {
        let (result, elapsed) = Self.timed {
            Result { try ProcessRun.run("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"],
                                        timeout: 0.3, grace: 0.3) }
        }
        #expect(throws: ProcessRunError.timedOut) { try result.get() }
        #expect(elapsed < 5)
    }

    /// Bug caught: a grandchild inheriting stdout keeps the call blocked until the grandchild exits.
    @Test func grandchildHoldingStdoutDoesNotBlock() throws {
        let (output, elapsed) = try Self.timed {
            try ProcessRun.run("/bin/sh", ["-c", "sleep 8 & echo hi"], timeout: 5, grace: 0.5)
        }
        #expect(output.status == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "hi\n")
        #expect(elapsed < 4)
    }

    @Test func outputAndStatusAreReturned() throws {
        let output = try ProcessRun.run("/bin/sh", ["-c", "printf abc; exit 3"], timeout: 5)
        #expect(output.status == 3)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "abc")
    }

    /// Bug caught: an unbounded Spotlight query stalling the classify pipeline; a zero deadline must still return.
    @Test func spotlightQueryHonorsDeadline() {
        let (_, elapsed) = Self.timed {
            SpotlightLastUsed.query(root: NSHomeDirectory(), minBytes: 0, deadline: 0.001)
        }
        #expect(elapsed < 10)
    }
}
