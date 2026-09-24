import Foundation
import MonitorModel

/// The interval/pause state machine behind `MockPipeline` (`MonitorRuntime`, ARCHITECTURE §5.11):
/// interactive (popover or dashboard visible) → 1 s, background → 5 s, paused → no ticks (§4's loop —
/// "interactive samples immediately; paused sleeps and takes no samples" — applied to the mock stream).
///
/// Kept in `MonitorMocks` (not `MonitorRuntime`, which owns the actual timer `Task`) so it can be tested
/// synchronously here, with no real `Task.sleep`, no `LiveModel` dependency, and no new package
/// dependency for `MonitorMocksTests` — `MockPipeline` is a thin adapter over this plus the timer loop.
@MainActor
public final class MockFeeder {
    private let provider: MockDataProvider
    public private(set) var tick = 0
    public private(set) var mode: SamplingMode = .background
    public private(set) var paused = false

    public init(provider: MockDataProvider) {
        self.provider = provider
    }

    /// `nil` while paused — no sampling, mirroring `SamplingMode.paused.interval`.
    public var interval: Duration? { paused ? nil : mode.interval }

    public func setVisibility(_ visibility: UIVisibility) {
        mode = visibility.mode
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    /// Advances one tick and returns the next frame, or `nil` while paused (no frame to apply).
    public func nextFrame() -> SystemFrame? {
        guard !paused else { return nil }
        defer { tick += 1 }
        return provider.frame(at: tick)
    }
}
