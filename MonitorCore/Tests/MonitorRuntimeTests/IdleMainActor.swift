import Foundation
import Testing

/// Defers each test of the suite until the main actor is responsive (copy of MonitorScreensTests/Support/
/// IdleMainActor.swift; test targets share no support module).
///
/// Why: all test targets run in one process, and Swift Testing starts every test at once, so all `@MainActor`
/// tests (snapshot renders, the screen catalog) land on the main queue together: ~30 s of FIFO backlog at the
/// start of a full `swift test`. The pipeline's commands and frames hop through the main actor, so a harness
/// waiting a bounded time for ticks fails on queueing alone. Waiting here (off the main actor) until round trips
/// are fast again starts such tests after the initial wave; their own timing bounds stay as they are.
/// Apply as `@Suite(.idleMainActor)`.
struct IdleMainActorTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? nil : self            // one scope per test function, none for the suite itself
    }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        await MainActorLatency.waitUntilIdle()
        try await function()
    }
}

extension Trait where Self == IdleMainActorTrait {
    static var idleMainActor: Self { Self() }
}

enum MainActorLatency {
    /// Returns once `streak` consecutive main-actor round trips each took under `threshold`, or after `cap`
    /// (then the test runs anyway and its own bounds decide).
    static func waitUntilIdle(threshold: Duration = .milliseconds(50), streak: Int = 3,
                              cap: Duration = .seconds(120)) async {
        let deadline = ContinuousClock.now + cap
        var quiet = 0
        while quiet < streak, ContinuousClock.now < deadline {
            let t0 = ContinuousClock.now
            await MainActor.run {}
            quiet = ContinuousClock.now - t0 < threshold ? quiet + 1 : 0
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
