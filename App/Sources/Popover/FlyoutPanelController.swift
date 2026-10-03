import AppKit
import MonitorModel
import MonitorScreens
import MonitorUIKit
import os
import SwiftUI

/// Never key or main: the popover keeps key status (Esc, ⌘ shortcuts) while the flyout is shown. Left-mouse events
/// go straight to the hit-tested view, so a click lands without the panel becoming key (a non-key window may
/// otherwise swallow the first click).
final class FlyoutPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    private weak var mouseDownView: NSView?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            guard let content = contentView,
                  let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                                            ?? event.locationInWindow)
            else { break }
            mouseDownView = hit
            hit.mouseDown(with: event)
            return
        case .leftMouseDragged:
            guard let view = mouseDownView else { break }
            view.mouseDragged(with: event)
            return
        case .leftMouseUp:
            guard let view = mouseDownView else { break }
            mouseDownView = nil
            view.mouseUp(with: event)
            return
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// Hosting view of the flyout: takes the first click, reports the pointer over the whole panel (AppKit tracking
/// area with mouse-moved: SwiftUI hover is unreliable in a never-key window) and content-size changes (rows come
/// and go with live updates). `onPointer` gets the location in this (flipped) view = `FlyoutPointer.space`, nil on
/// exit.
final class FlyoutHostingView: NSHostingView<AnyView> {
    var onPointer: (@MainActor (CGPoint?) -> Void)?
    var onSizeChange: (@MainActor () -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways,
                                                         .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === tracking { onPointer?(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === tracking { onPointer?(nil) }
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

/// Top-apps flyout beside the popover (DESIGN §2.22): a borderless non-activating `NSPanel` at the popover's level
/// (`.popUpMenu`), dark, never key, hosting `FlyoutView`. `HoverIntent` decides when it shows, switches and hides
/// from the popover rows' hover events (`PopoverRoot(onRowHover:)`), the pointer over the flyout itself and the
/// safe-triangle aim (`MenuAim`, sampled by a mouse-moved monitor while the popover is open). The hosting view
/// exists only while shown; the popover calls `activate()` on open, `dismiss()` on close and `reposition()` when
/// it moves.
@MainActor
final class FlyoutPanelController {
    /// The open popover: its window and hosting view (row frames are in that view's flipped coordinates).
    struct Popover {
        var window: NSWindow
        var hostView: NSView
        var screen: NSScreen?
    }

    /// Which row's flyout is shown; the popover environment reads it (source-row highlight).
    let state = FlyoutState()
    /// Called with true before the flyout appears (before placement) and false once it is gone; the popover hides
    /// the volume-mixer side panel meanwhile (both use the popover's left side).
    var onVisibleChange: (@MainActor (Bool) -> Void)?
    private let pointer = FlyoutPointer()
    private let env: AppEnvironment
    private let popover: @MainActor () -> Popover?
    private var panel: FlyoutPanel?
    private var host: FlyoutHostingView?
    /// Each row's frame in the popover hosting view (from its hover/geometry events).
    private var rowFrames: [MonitorModel.Category: CGRect] = [:]
    private var lastSize: CGSize?
    private var placeScheduled = false
    private var moveMonitor: Any?
    private var lastPointer: CGPoint?
    private var currentPointer: CGPoint?
    private let intent: HoverIntent<MonitorModel.Category>
    private static let log = Logger(subsystem: "dev.telltale", category: "Flyout")
    static let gap: CGFloat = 6

    init(env: AppEnvironment, popover: @escaping @MainActor () -> Popover?) {
        self.env = env
        self.popover = popover
        intent = HoverIntent(schedule: { delay, action in
            let task = Task { @MainActor in
                try? await Task.sleep(for: delay)
                if !Task.isCancelled { action() }
            }
            return { task.cancel() }
        })
        intent.onShow = { [weak self] c in self?.show(c) }
        intent.onHide = { [weak self] in self?.hide() }
        intent.aiming = { [weak self] in self?.aiming() ?? false }
    }

    var window: NSWindow? { panel }

    /// Popover opened: sample the pointer for the safe triangle.
    func activate() {
        guard moveMonitor == nil else { return }
        moveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.lastPointer = self?.currentPointer
                self?.currentPointer = NSEvent.mouseLocation
            }
            return event
        }
    }

    /// Popover closed: hide at once and forget the rows and the pointer.
    func dismiss() {
        intent.dismiss()
        rowFrames.removeAll()
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        lastPointer = nil
        currentPointer = nil
    }

    /// A popover row's hover/geometry event (frame in the popover hosting view).
    func rowHover(_ event: PopoverRowHover) {
        if event.frame.width > 0 { rowFrames[event.category] = event.frame }
        switch event.phase {
        case .entered: intent.rowEntered(event.category)
        case .exited: intent.rowExited(event.category)
        case .show: intent.showNow(event.category)
        case .geometry: if event.category == state.shown { reposition() }
        }
    }

    /// The popover moved or re-laid out: re-anchor to the (converted) row frame.
    func reposition() {
        guard panel != nil else { return }
        place(force: true)
    }

    // MARK: Panel

    private func show(_ category: MonitorModel.Category) {
        state.shown = category
        let root = AnyView(FlyoutView(category: category).environment(pointer).telltaleEnvironment(env.context()))
        if let host {
            host.rootView = root                         // switch rows: same panel, new content
        } else {
            onVisibleChange?(true)
            let host = FlyoutHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
            host.onPointer = { [weak self] p in self?.pointerMoved(p) }
            host.onSizeChange = { [weak self] in self?.schedulePlace() }
            let panel = FlyoutPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.contentView = host
            panel.setAccessibilityLabel("Top apps")
            self.panel = panel
            self.host = host
        }
        place(force: true)
        panel?.orderFrontRegardless()
        syncHover()
        announce(category)
    }

    private func hide() {
        state.shown = nil
        pointer.location = nil
        pointer.inside = false
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil                          // tear down the SwiftUI tree (and its observation)
        host?.onPointer = nil
        host?.onSizeChange = nil
        self.panel = nil
        host = nil
        lastSize = nil
        onVisibleChange?(false)
    }

    /// VoiceOver: move to the flyout and read its header plus the top 3 lines.
    private func announce(_ category: MonitorModel.Category) {
        // Only for VoiceOver users: otherwise every hover switch would post an announcement for nothing.
        guard let host, NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: host, notification: .layoutChanged, userInfo: [.uiElements: [host]])
        let text = FlyoutView.announcement(category, live: env.live, units: env.settings.units)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Pointer

    private func pointerMoved(_ p: CGPoint?) {
        pointer.location = p
        let inside = p != nil
        if pointer.inside != inside { pointer.inside = inside }
        intent.flyoutHover(inside)
    }

    /// Re-derives "pointer in flyout" from the real mouse position: a panel that moved or appeared under a still
    /// pointer gets no enter/exit, and a missed exit must not keep the flyout open.
    private func syncHover() {
        guard let panel, let host else { return }
        let mouse = NSEvent.mouseLocation
        if panel.frame.contains(mouse) {
            pointerMoved(host.convert(panel.convertPoint(fromScreen: mouse), from: nil))
        } else {
            pointerMoved(nil)
        }
    }

    /// Safe triangle: the latest pointer move heads for the flyout's near edge.
    private func aiming() -> Bool {
        guard let panel, let last = lastPointer, let now = currentPointer else { return false }
        return MenuAim.isAiming(from: last, to: now, flyout: panel.frame)
    }

    // MARK: Placement

    private func schedulePlace() {
        guard !placeScheduled else { return }
        placeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.placeScheduled = false
            self?.place(force: false)
        }
    }

    /// `force` false (content-size change): skipped when the fitting size is unchanged.
    private func place(force: Bool) {
        guard let panel, let host, let category = state.shown, let pop = popover(),
              let screen = pop.screen ?? NSScreen.main else { return }
        let size = host.fittingSize
        if !force, size == lastSize { return }
        lastSize = size
        let row = rowFrames[category].map { pop.window.convertToScreen(pop.hostView.convert($0, to: nil)) }
            ?? NSRect(x: pop.window.frame.minX, y: pop.window.frame.maxY, width: 0, height: 0)
        let f = FlyoutPlacement.frame(rowRect: row, popoverFrame: pop.window.frame, visibleFrame: screen.visibleFrame,
                                      size: size, gap: Self.gap)
        guard f != panel.frame else { return }
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
        syncHover()
        Self.log.debug("""
            place \(category.rawValue, privacy: .public) row=\(String(describing: row), privacy: .public) \
            → \(String(describing: f), privacy: .public)
            """)
    }
}
