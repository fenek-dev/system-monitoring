import AppKit
import MonitorModel
import MonitorScreens
import MonitorUIKit
import os
import SwiftUI

/// Never key or main: the popover keeps key status (Esc, ⌘ shortcuts) while the flyout is shown.
final class FlyoutPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view of the flyout: takes the first click (the panel is never key and the app is not active), reports
/// pointer enter/exit over the whole panel (AppKit tracking area: SwiftUI hover is unreliable in a non-key window)
/// and content-size changes (rows come and go with live updates).
final class FlyoutHostingView: NSHostingView<AnyView> {
    var onHover: (@MainActor (Bool) -> Void)?
    var onSizeChange: (@MainActor () -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: ["flyout": true])
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === tracking { onHover?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === tracking { onHover?(false) }
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

/// Top-apps flyout beside the popover (DESIGN §2.22): a borderless non-activating `NSPanel` at the popover's level
/// (`.popUpMenu`), dark, never key, hosting `FlyoutView`. `HoverIntent` decides when it shows, switches and hides
/// from the popover rows' hover events (`PopoverRoot(onRowHover:)`) and the pointer over the flyout itself.
/// The hosting view exists only while shown; the popover calls `dismiss()` when it closes.
@MainActor
final class FlyoutPanelController {
    private let env: AppEnvironment
    /// The popover panel's frame and screen (placement), nil when it is closed.
    private let popover: @MainActor () -> (frame: NSRect, screen: NSScreen?)?
    private var panel: FlyoutPanel?
    private var host: FlyoutHostingView?
    private var category: MonitorModel.Category?
    /// Screen rect of each row, from its latest hover event.
    private var rowRects: [MonitorModel.Category: NSRect] = [:]
    private var placeScheduled = false
    private static let log = Logger(subsystem: "dev.telltale", category: "Flyout")
    static let gap: CGFloat = 6

    private let intent: HoverIntent<MonitorModel.Category>

    init(env: AppEnvironment, popover: @escaping @MainActor () -> (frame: NSRect, screen: NSScreen?)?) {
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
    }

    var window: NSWindow? { panel }

    /// A popover row's hover event, its frame already converted to screen coordinates.
    func rowHover(_ category: MonitorModel.Category, phase: PopoverRowHover.Phase, screenRect: NSRect) {
        if screenRect.width > 0 { rowRects[category] = screenRect }
        switch phase {
        case .entered: intent.rowEntered(category)
        case .exited: intent.rowExited(category)
        case .show: intent.showNow(category)
        }
    }

    /// Popover closed: hide at once and forget the rows.
    func dismiss() {
        intent.dismiss()
        rowRects.removeAll()
    }

    // MARK: Panel

    private func show(_ category: MonitorModel.Category) {
        self.category = category
        let root = AnyView(FlyoutView(category: category).telltaleEnvironment(env.context()))
        if let host {
            host.rootView = root                         // switch rows: same panel, new content
        } else {
            let host = FlyoutHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
            host.onHover = { [weak self] inside in self?.intent.flyoutHover(inside) }
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
            panel.becomesKeyOnlyIfNeeded = true
            panel.contentView = host
            panel.setAccessibilityLabel("Top apps")
            self.panel = panel
            self.host = host
        }
        place()
        panel?.orderFrontRegardless()
    }

    private func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil                          // tear down the SwiftUI tree (and its observation)
        host?.onHover = nil
        host?.onSizeChange = nil
        self.panel = nil
        host = nil
        category = nil
    }

    private func schedulePlace() {
        guard !placeScheduled else { return }
        placeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.placeScheduled = false
            self?.place()
        }
    }

    private func place() {
        guard let panel, let host, let category, let pop = popover(),
              let screen = pop.screen ?? NSScreen.main else { return }
        let size = host.fittingSize
        let row = rowRects[category] ?? NSRect(x: pop.frame.minX, y: pop.frame.maxY, width: 0, height: 0)
        let f = FlyoutPlacement.frame(rowRect: row, popoverFrame: pop.frame, visibleFrame: screen.visibleFrame,
                                      size: size, gap: Self.gap)
        if f != panel.frame {
            panel.setFrame(f, display: true)
            panel.invalidateShadow()
        }
        Self.log.debug("""
            place \(category.rawValue, privacy: .public) row=\(String(describing: row), privacy: .public) \
            → \(String(describing: f), privacy: .public)
            """)
    }
}
