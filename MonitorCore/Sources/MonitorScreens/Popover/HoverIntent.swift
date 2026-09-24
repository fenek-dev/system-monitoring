import Foundation

/// Hover intent of the popover's top-apps flyout (DESIGN §2.22), as a state machine over an injected timer:
/// - hovering a row for `openDelay` (250 ms) shows its flyout; leaving earlier shows nothing;
/// - while a flyout is shown (or closing), entering another row switches to it at once;
/// - leaving the row starts a `closeGrace` (200 ms) close; entering the flyout (hover bridge) or a row cancels it;
///   leaving the flyout with no row hovered starts it again;
/// - `showNow` (the "Show top apps" accessibility action) shows at once; `dismiss` (popover closed) hides.
/// Enter/exit events may arrive in either order when moving between adjacent rows.
@MainActor
public final class HoverIntent<Key: Hashable> {
    public static var openDelay: Duration { .milliseconds(250) }
    public static var closeGrace: Duration { .milliseconds(200) }

    /// Runs the action after the delay unless the returned cancel closure is called first.
    public typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> @MainActor () -> Void

    public var onShow: @MainActor (Key) -> Void = { _ in }
    public var onHide: @MainActor () -> Void = {}

    /// The key whose flyout is shown.
    public private(set) var shown: Key?
    private var hoveredRow: Key?
    private var inFlyout = false
    private var cancelTimer: (@MainActor () -> Void)?
    private let schedule: Schedule

    public init(schedule: @escaping Schedule) {
        self.schedule = schedule
    }

    public func rowEntered(_ key: Key) {
        hoveredRow = key
        if shown != nil {
            cancel()
            show(key)
        } else {
            start(Self.openDelay) { [weak self] in
                guard let self, self.hoveredRow == key else { return }
                self.show(key)
            }
        }
    }

    public func rowExited(_ key: Key) {
        guard hoveredRow == key else { return }      // the next row's enter already arrived
        hoveredRow = nil
        if shown == nil { cancel() } else if !inFlyout { startClose() }
    }

    public func flyoutHover(_ inside: Bool) {
        inFlyout = inside
        if inside {
            if shown != nil { cancel() }
        } else if shown != nil, hoveredRow == nil {
            startClose()
        }
    }

    public func showNow(_ key: Key) {
        cancel()
        show(key)
    }

    public func dismiss() {
        cancel()
        hoveredRow = nil
        inFlyout = false
        hide()
    }

    // MARK: Private

    private func show(_ key: Key) {
        guard shown != key else { return }
        shown = key
        onShow(key)
    }

    private func hide() {
        guard shown != nil else { return }
        shown = nil
        onHide()
    }

    private func startClose() {
        start(Self.closeGrace) { [weak self] in
            guard let self, self.hoveredRow == nil, !self.inFlyout else { return }
            self.hide()
        }
    }

    private func start(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        cancel()
        cancelTimer = schedule(delay) { [weak self] in
            self?.cancelTimer = nil
            action()
        }
    }

    private func cancel() {
        cancelTimer?()
        cancelTimer = nil
    }
}
