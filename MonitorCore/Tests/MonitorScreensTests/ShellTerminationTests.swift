import Foundation
@testable import MonitorScreens
import Testing

/// Fake runtime recording the order of shutdown steps.
@MainActor final class FakeRuntime {
    var events: [String] = []
    var shutdownDelay: Duration = .zero
    var hang = false

    func shutdown() async {
        events.append("shutdown.begin")
        if hang {
            try? await Task.sleep(for: .seconds(3600))
            return
        }
        if shutdownDelay > .zero { try? await Task.sleep(for: shutdownDelay) }
        events.append("store.flushed")
    }
}

@Suite("Shell termination") @MainActor
struct ShellTerminationTests {
    private func waitForReply(_ log: () -> [String], timeout: Duration = .seconds(2)) async {
        let end = ContinuousClock.now + timeout
        while !log().contains("reply"), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func closesUIThenShutsDownThenReplies() async {
        let rt = FakeRuntime()
        rt.shutdownDelay = .milliseconds(30)
        let t = TerminationController(timeout: .seconds(3),
                                      closeUI: { rt.events.append("ui.closed") },
                                      shutdown: { await rt.shutdown() },
                                      reply: { ok in rt.events.append(ok ? "reply" : "reply.false") })
        t.requestTermination()
        #expect(t.phase == .shuttingDown)
        await waitForReply { rt.events }
        #expect(rt.events == ["ui.closed", "shutdown.begin", "store.flushed", "reply"])
        #expect(t.phase == .done(timedOut: false))
    }

    @Test func hungShutdownRepliesAfterTimeout() async {
        let rt = FakeRuntime()
        rt.hang = true
        let t = TerminationController(timeout: .milliseconds(80), closeUI: {},
                                      shutdown: { await rt.shutdown() },
                                      reply: { _ in rt.events.append("reply") })
        let start = ContinuousClock.now
        t.requestTermination()
        await waitForReply { rt.events }
        let elapsed = ContinuousClock.now - start
        #expect(rt.events == ["shutdown.begin", "reply"])
        #expect(t.phase == .done(timedOut: true))
        #expect(elapsed >= .milliseconds(80) && elapsed < .seconds(1))
    }

    @Test func secondRequestIsAbsorbed() async {
        let rt = FakeRuntime()
        rt.shutdownDelay = .milliseconds(20)
        var replies = 0
        let t = TerminationController(timeout: .seconds(3), closeUI: {}, shutdown: { await rt.shutdown() },
                                      reply: { _ in replies += 1; rt.events.append("reply") })
        t.requestTermination()
        t.requestTermination()
        await waitForReply { rt.events }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(replies == 1)
        #expect(rt.events.filter { $0 == "shutdown.begin" }.count == 1)
    }
}
