import AppKit
import MonitorLive
import MonitorModel
import MonitorScreens

/// The menu bar item (DESIGN §4, ARCHITECTURE §5.13): glyph from `live.alert` (re-armed observation),
/// template when calm, dimmed when paused, one pulse per `pulseToken` change into critical; left click toggles
/// the popover, right/ctrl click shows the menu.
@MainActor
final class StatusItemController: NSObject {
    let item: NSStatusItem
    private let live: LiveModel
    private let onToggle: @MainActor () -> Void
    private let menuProvider: @MainActor () -> NSMenu
    private var loop: ObservationLoop<AlertState>?
    private var presenter = StatusItemPresenter()
    private var pulseTask: Task<Void, Never>?
    /// DEBUG `--status-preview`: overrides `live.alert` (mock stubs are always calm).
    var previewState: AlertState? { didSet { if let previewState { render(previewState) } } }

    init(live: LiveModel, onToggle: @escaping @MainActor () -> Void, menu: @escaping @MainActor () -> NSMenu) {
        self.live = live
        self.onToggle = onToggle
        menuProvider = menu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "dev.telltale.status"
        super.init()
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
        }
        loop = ObservationLoop({ [live] in live.alert }) { [weak self] state in
            guard let self, self.previewState == nil else { return }
            self.render(state)
        }
    }

    var button: NSStatusBarButton? { item.button }

    /// Open-popover highlight (DESIGN §3.1).
    func setHighlighted(_ on: Bool) { item.button?.highlight(on) }

    /// Called before the right-click menu opens (closes the popover).
    var willShowMenu: (@MainActor () -> Void)?

    /// Screen rect of the button (popover anchor); nil when the item is hidden (e.g. behind the notch on a full
    /// menu bar: the window exists but is occluded), so the popover falls back to a centered placement.
    /// The screen the status item lives on (popover placement), also when the item itself is occluded.
    var buttonScreen: NSScreen? { item.button?.window?.screen }

    var buttonScreenFrame: NSRect? {
        guard let b = item.button, let w = b.window, w.occlusionState.contains(.visible) else { return nil }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }

    /// Applies only what changed (`StatusItemPresenter`): per-tick alert noise (runaway `cpuPercent`) neither
    /// redraws nor cancels a running pulse.
    func render(_ state: AlertState) {
        let u = presenter.apply(state, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        if let line = u.statusLine {
            item.button?.toolTip = line
            item.button?.setAccessibilityLabel("Warden, \(line)")
        }
        if u.cancelPulse { pulseTask?.cancel() }
        if u.glyph != nil || u.cancelPulse { item.button?.image = StatusIconRenderer.image(for: state) }
        if u.startPulse { runPulse(state) }
    }

    /// 18 frames at 30 fps by swapping `button.image`, then the static critical image (DESIGN §4.3).
    func runPulse(_ state: AlertState) {
        pulseTask?.cancel()
        pulseTask = Task { @MainActor [weak self] in
            for f in StatusPulse.frames {
                guard let self, !Task.isCancelled else { return }
                self.item.button?.image = StatusIconRenderer.image(for: state, pulse: f)
                try? await Task.sleep(for: StatusPulse.frameInterval)
            }
            guard let self, !Task.isCancelled else { return }
            self.item.button?.image = StatusIconRenderer.image(for: state)
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            willShowMenu?()
            let menu = menuProvider()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        } else {
            onToggle()
        }
    }

    func remove() {
        loop?.cancel()
        pulseTask?.cancel()
        NSStatusBar.system.removeStatusItem(item)
    }
}
