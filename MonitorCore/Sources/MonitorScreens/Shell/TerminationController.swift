import Foundation
import os

/// Quit flow (ARCHITECTURE §4, §5.13): `applicationShouldTerminate` → `.terminateLater`; close the UI; await
/// `runtime.shutdown()` (engine stop + store flush) bounded by `timeout` (3 s); then reply `true` either way.
/// A second quit request while one is running is absorbed (no second shutdown).
@MainActor
public final class TerminationController {
    public enum Phase: Equatable, Sendable { case idle, shuttingDown, done(timedOut: Bool) }

    public private(set) var phase: Phase = .idle
    private let timeout: Duration
    private let closeUI: @MainActor () -> Void
    private let shutdown: @MainActor () async -> Void
    private let reply: @MainActor (Bool) -> Void
    private let log = Logger(subsystem: "dev.telltale", category: "Shell")

    public init(timeout: Duration = .seconds(3), closeUI: @escaping @MainActor () -> Void,
                shutdown: @escaping @MainActor () async -> Void, reply: @escaping @MainActor (Bool) -> Void) {
        self.timeout = timeout
        self.closeUI = closeUI
        self.shutdown = shutdown
        self.reply = reply
    }

    /// Call from `applicationShouldTerminate`; always answer `.terminateLater`.
    public func requestTermination() {
        guard phase == .idle else { return }
        phase = .shuttingDown
        closeUI()
        let started = ContinuousClock.now
        log.notice("terminate: shutdown started")
        Task { @MainActor in
            let completed = await Self.run(shutdown, timeout: timeout)
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log.notice("terminate: shutdown \(completed ? "finished" : "timed out", privacy: .public) after \(ms) ms")
            phase = .done(timedOut: !completed)
            reply(true)
        }
    }

    /// Runs `operation`; returns false if `timeout` elapsed first. The loser is cancelled (the timer always; the
    /// operation only gets a cancellation request, it may keep running until the process exits).
    public static func run(_ operation: @escaping @MainActor () async -> Void, timeout: Duration) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let race = Race(cont)
            race.work = Task { @MainActor in
                await operation()
                race.finish(true)
            }
            race.timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { race.finish(false) }
            }
        }
    }

    @MainActor private final class Race {
        private var cont: CheckedContinuation<Bool, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
        func finish(_ completed: Bool) {
            guard let c = cont else { return }
            cont = nil
            (completed ? timer : work)?.cancel()
            c.resume(returning: completed)
        }
    }
}
