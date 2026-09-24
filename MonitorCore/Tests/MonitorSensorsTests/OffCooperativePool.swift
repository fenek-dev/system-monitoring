import Foundation
import Testing

/// Runs each test of the suite (or the one test) on dedicated threads instead of the Swift cooperative pool.
///
/// Why: blocking calls (`sample(firstWait:)`, `waitIdle`, `LatencyBox.burst`, `Thread.sleep`, subprocess waits) park
/// the calling thread. On a cooperative-pool thread that starves the whole process: the pool has one thread per CPU,
/// and once they are all parked the kernel admits no non-overcommit GCD threads, so the `.utility` concurrent queues
/// the sensors (and other suites) depend on stall. Here the blocked thread is ours; the pool stays free.
///
/// The test keeps its task (a task-executor preference, not a detached thread), so `#expect`/`Issue.record` still
/// attribute to the right test. Only nonisolated tests move; `@MainActor` tests are unaffected.
/// Apply as `@Suite(.offCooperativePool)` or `@Test(.offCooperativePool)`.
struct OffCooperativePoolTrait: SuiteTrait, TestTrait, TestScoping {
    static let threadName = "dev.telltale.tests.off-cooperative-pool"

    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? nil : self            // one scope per test function, none for the suite itself
    }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        if #available(macOS 15.0, *) {
            try await withTaskExecutorPreference(DedicatedThreadExecutor.shared) { try await function() }
        } else {
            try await function()
        }
    }
}

extension Trait where Self == OffCooperativePoolTrait {
    static var offCooperativePool: Self { Self() }
}

/// `spawn:` seam for boxes whose work runs on a `.utility` concurrent queue (`RootMemoryBox`, `ReverseDNS`).
/// Such a queue is non-overcommit: while other suites keep every cooperative-pool thread busy (a full run's first
/// seconds), it gets no thread for hundreds of ms, and a test's short wait measures the machine, not the box.
enum TestSpawn {
    static let dedicatedThread: @Sendable (@escaping @Sendable () -> Void) -> Void = { Thread.detachNewThread($0) }
}

/// Task executor that runs every job on a fresh thread (jobs of a blocking test are few and long).
@available(macOS 15.0, *)
final class DedicatedThreadExecutor: TaskExecutor {
    static let shared = DedicatedThreadExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        let thread = Thread { job.runSynchronously(on: executor) }
        thread.name = OffCooperativePoolTrait.threadName
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

@Suite struct OffCooperativePoolTraitTests {
    /// Guards the trait itself: a sync test body runs on the dedicated thread, not a pool thread.
    @Test(.offCooperativePool) func syncBodyRunsOnADedicatedThread() {
        #expect(Thread.current.name == OffCooperativePoolTrait.threadName)
    }

    @Test(.offCooperativePool) func asyncBodyResumesOnADedicatedThread() async throws {
        try await Task.sleep(for: .milliseconds(1))
        #expect(Self.threadName() == OffCooperativePoolTrait.threadName)
    }

    @Test func withoutTheTraitTheBodyRunsOnThePool() {
        #expect(Thread.current.name != OffCooperativePoolTrait.threadName)
    }

    private static func threadName() -> String? { Thread.current.name }
}
