import AppKit
import MonitorUIKit
import SwiftUI

/// Whether the App's Carbon registration of `SettingsStore.overlayHotKey` succeeded (spec 2026-09-25 overlay,
/// "Hotkey"): `.unavailable` when another app owns the combination. The App sets it; renders default to
/// `.registered`.
public enum HotKeyStatus: Equatable, Sendable { case registered, unavailable }

public extension EnvironmentValues {
    @Entry var overlayHotKeyStatus: HotKeyStatus = .registered
}

/// Settings › Overlay "Shortcut" recorder. Clicking starts recording ("Type shortcut…"); the next keyDown with
/// at least one of ⌘⌥⌃ is saved, Esc cancels, and anything else flashes "Needs ⌘, ⌥ or ⌃" and keeps recording.
/// Keys are captured by a local `keyDown` monitor that exists only while recording (and swallows the events).
public struct HotKeyRecorder: View {
    public enum Outcome: Equatable, Sendable {
        case saved(HotKeySpec)
        case cancelled
        case invalid
    }

    static let escapeKeyCode: UInt16 = 53                      // kVK_Escape
    static let recordingPrompt = "Type shortcut…"
    static let invalidMessage = "Needs ⌘, ⌥ or ⌃"

    @Binding private var spec: HotKeySpec
    @State private var recording = false
    @State private var invalid = false

    public init(spec: Binding<HotKeySpec>) { _spec = spec }

    /// Pure key handling: `keyCode`/`flags` as `NSEvent.keyCode` / `NSEvent.modifierFlags.rawValue`.
    public static func handle(keyCode: UInt16, flags: UInt) -> Outcome {
        if keyCode == escapeKeyCode { return .cancelled }
        guard let spec = HotKeySpec.from(keyCode: keyCode, modifierFlags: flags) else { return .invalid }
        return .saved(spec)
    }

    public var body: some View {
        Button {
            recording.toggle()
            invalid = false
        } label: {
            Text(title)
                .font(ShellStyle.body13).monospacedDigit()
                .foregroundStyle(invalid ? TTColor.statusElevated
                                 : recording ? ShellStyle.textSecondary : ShellStyle.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(minWidth: 120, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous).fill(TTColor.fillField))
                .overlay(RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous)
                    .strokeBorder(recording ? ShellStyle.accent : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(KeyCapture(isActive: recording, onKey: receive))
        .onDisappear { recording = false }
        .task(id: invalid) {
            guard invalid else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { invalid = false }
        }
        .help(recording ? "Press a shortcut, or Esc to cancel" : "Click to record a new shortcut")
        .accessibilityLabel("Overlay shortcut")
        .accessibilityValue(title)
    }

    private var title: String {
        if invalid { return Self.invalidMessage }
        return recording ? Self.recordingPrompt : spec.display
    }

    private func receive(_ keyCode: UInt16, _ flags: UInt) {
        switch Self.handle(keyCode: keyCode, flags: flags) {
        case .saved(let s):
            spec = s
            recording = false
            invalid = false
        case .cancelled:
            recording = false
            invalid = false
        case .invalid:
            invalid = true
        }
    }
}

/// Installs a local `keyDown` monitor while `isActive`; removed when deactivated or when the view goes away.
private struct KeyCapture: NSViewRepresentable {
    var isActive: Bool
    var onKey: @MainActor (UInt16, UInt) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onKey = onKey
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    @MainActor final class Coordinator {
        var onKey: (@MainActor (UInt16, UInt) -> Void)?
        private var monitor: Any?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let keyCode = event.keyCode
                    let flags = event.modifierFlags.rawValue
                    MainActor.assumeIsolated { self?.onKey?(keyCode, flags) }
                    return nil                                      // swallow: recording owns the keyboard
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }
}
