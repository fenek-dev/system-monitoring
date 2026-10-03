import AppKit
import MonitorUIKit
import SwiftUI

/// Borderless non-activating panel hosting `TTExtraDimHUD` (extra-dim spec §6): click-through, status-bar level, on
/// every Space and over full-screen apps, centered horizontally in the lower third of the built-in screen. Shown on
/// each action, fades out 1.2 s after the last one; the hosting view is released when hidden. It sits under the
/// gamma too, so it dims with the screen.
@MainActor
final class ExtraDimHUDPanel {
    static let visibleFor: Duration = .milliseconds(1200)
    static let fadeDuration = 0.25
    /// Room around the card for its shadow.
    private static let margin: CGFloat = 24

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// Bumped by every show(), so a fade that finishes after a newer show() leaves the panel up.
    private var generation = 0

    func show(_ content: TTExtraDimHUD.Content, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: TTExtraDimHUD(content).padding(Self.margin))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        let f = screen.frame
        panel.setFrame(CGRect(x: (f.midX - size.width / 2).rounded(), y: (f.minY + f.height / 6 - size.height / 2).rounded(),
                              width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.visibleFor)
            guard !Task.isCancelled else { return }
            self?.fadeOut()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func fadeOut() {
        guard let panel else { return }
        let shown = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }   // a newer show() started during the fade
                self.hide()
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                            defer: true)
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}
