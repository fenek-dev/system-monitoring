import AppKit
import MonitorScreens
import SwiftUI

/// Hosting view of the mixer panel: takes the first click and reports pointer enter/exit over the whole panel
/// (AppKit tracking area, active in a non-key window of an inactive app).
final class MixerHostingView: NSHostingView<AnyView> {
    var onPointerInside: (@MainActor (Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === tracking { onPointerInside?(true) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === tracking { onPointerInside?(false) }
    }
}

/// Volume-mixer side panel beside the popover (`SidePanelPlacement`: left, else right), toggled from the popover
/// header and shown with it while `MixerModel.panelOpen`, except while the top-apps flyout takes the same side. A borderless non-activating `PopoverPanel` at the
/// popover's level; key follows the pointer between the two panels (hover, keyboard and scroll need a key window),
/// and the popover treats either being key as "still open". The hosting view exists only while shown.
@MainActor
final class MixerPanelController {
    let model: MixerModel
    private let popover: @MainActor () -> NSWindow?
    private var panel: PopoverPanel?
    private var host: MixerHostingView?
    private var sizeObservation: NSKeyValueObservation?
    static let gap: CGFloat = 6

    /// `popover` is the open popover panel (nil when closed).
    init(model: MixerModel, popover: @escaping @MainActor () -> NSWindow?) {
        self.model = model
        self.popover = popover
    }

    var window: NSWindow? { panel }

    func show() {
        guard panel == nil, popover() != nil else { return }
        let root = PopoverContainer(drawsShadow: false, width: MixerView.width) {
            MixerView(engine: model.engine, wheel: model.wheel)
        }
        let host = MixerHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        host.onPointerInside = { [weak self] inside in self?.pointerInside(inside) }
        let panel = PopoverPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        panel.setAccessibilityLabel("Volume Mixer")
        self.panel = panel
        self.host = host
        sizeObservation = host.observe(\.intrinsicContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.reposition() }
        }
        reposition()
        panel.orderFrontRegardless()
        // First layout pass can finish after this run-loop turn: place once more with the final size.
        DispatchQueue.main.async { [weak self] in self?.reposition() }
    }

    func hide() {
        guard let panel else { return }
        model.wheel.hoveredID = nil
        sizeObservation = nil
        host?.onPointerInside = nil
        let wasKey = panel.isKeyWindow
        panel.orderOut(nil)
        panel.contentView = nil                          // tear down the SwiftUI tree (and its observation)
        self.panel = nil
        host = nil
        if wasKey { popover()?.makeKey() }
    }

    /// The popover moved or resized, or the content changed size.
    func reposition() {
        guard let panel, let host, let pop = popover(), let screen = pop.screen ?? NSScreen.main else { return }
        host.layoutSubtreeIfNeeded()
        let f = SidePanelPlacement.frame(popoverFrame: pop.frame, visibleFrame: screen.visibleFrame,
                                         size: host.fittingSize, gap: Self.gap)
        guard f != panel.frame else { return }
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    /// Key follows the pointer: into the mixer on enter, back to the popover on exit.
    private func pointerInside(_ inside: Bool) {
        guard let panel else { return }
        if inside {
            if !panel.isKeyWindow { panel.makeKey() }
        } else if panel.isKeyWindow {
            popover()?.makeKey()
        }
    }
}
