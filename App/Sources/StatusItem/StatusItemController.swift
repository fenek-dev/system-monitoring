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
    private var lastToken: Int?
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

    /// Screen rect of the button (popover anchor).
    var buttonScreenFrame: NSRect? {
        guard let b = item.button, let w = b.window else { return nil }
        return w.convertToScreen(b.convert(b.bounds, to: nil))
    }

    func render(_ state: AlertState) {
        let pulse = StatusPulse.shouldPulse(previousToken: lastToken, state: state,
                                            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        lastToken = state.pulseToken
        let line = StatusLine.text(for: state)
        item.button?.toolTip = line
        item.button?.setAccessibilityLabel("Telltale, \(line)")
        pulseTask?.cancel()
        item.button?.image = StatusIconRenderer.image(for: state)
        if pulse { runPulse(state) }
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
