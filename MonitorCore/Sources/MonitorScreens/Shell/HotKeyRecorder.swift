import AppKit
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Whether the App's Carbon registration of `SettingsStore.overlayHotKey` succeeded (spec 2026-09-25 overlay,
/// "Hotkey"): `.unavailable` when another app owns the combination. The App sets it; renders default to
/// `.registered`.
public enum HotKeyStatus: Equatable, Sendable { case registered, unavailable }

public extension EnvironmentValues {
    @Entry var overlayHotKeyStatus: HotKeyStatus = .registered
}

/// Settings › Overlay "Shortcut" recorder. Clicking starts recording ("Type shortcut…"); the next keyDown in this
/// window with at least one of ⌘⌥⌃ is saved, Esc cancels, a ⌘-only standard shortcut flashes "Reserved by macOS",
/// anything else flashes "Needs ⌘, ⌥ or ⌃" (both keep recording). The window resigning key stops recording.
/// While recording, `AppCommands.setHotKeyRecording(true)` lets the App unregister the global hotkey.
public struct HotKeyRecorder: View {
    public enum Outcome: Equatable, Sendable {
        case saved(HotKeySpec)
        case cancelled
        case invalid
        case reserved
    }

    static let escapeKeyCode: UInt16 = 53                      // kVK_Escape
    static let recordingPrompt = "Type shortcut…"

    @Binding private var spec: HotKeySpec
    @Environment(\.appCommands) private var commands
    @State private var recording = false
    @State private var message: String?
    @State private var flashID = 0

    public init(spec: Binding<HotKeySpec>) { _spec = spec }

    /// Pure key handling: `keyCode`/`flags` as `NSEvent.keyCode` / `NSEvent.modifierFlags.rawValue`.
    public static func handle(keyCode: UInt16, flags: UInt) -> Outcome {
        if keyCode == escapeKeyCode { return .cancelled }
        let spec = HotKeySpec.unchecked(keyCode: keyCode, modifierFlags: flags)
        if spec.isReserved { return .reserved }
        return spec.isValid ? .saved(spec) : .invalid
    }

    /// Flash text for a rejected key; nil for the outcomes that end recording.
    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .invalid: "Needs ⌘, ⌥ or ⌃"
        case .reserved: "Reserved by macOS"
        case .saved, .cancelled: nil
        }
    }

    public var body: some View {
        Button {
            recording.toggle()
            message = nil
        } label: {
            Text(title)
                .font(ShellStyle.body13).monospacedDigit()
                .foregroundStyle(message != nil ? TTColor.statusElevated
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
        .background(KeyCapture(isActive: recording, onKey: receive, onResignKey: stop,
                               onRecording: commands.setHotKeyRecording))
        .onDisappear(perform: stop)
        .task(id: flashID) {                                   // each flash restarts the 1.5-s timer
            guard message != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { message = nil }
        }
        .help(recording ? "Press a shortcut, or Esc to cancel" : "Click to record a new shortcut")
        .accessibilityLabel("Overlay shortcut")
        .accessibilityValue(title)
    }

    private var title: String {
        if let message { return message }
        return recording ? Self.recordingPrompt : spec.display
    }

    private func stop() {
        recording = false
        message = nil
    }

    private func receive(_ keyCode: UInt16, _ flags: UInt) {
        let outcome = Self.handle(keyCode: keyCode, flags: flags)
        switch outcome {
        case .saved(let s):
            spec = s
            stop()
        case .cancelled:
            stop()
        case .invalid, .reserved:
            message = Self.message(for: outcome)
            flashID &+= 1
        }
    }
}

/// Hosts the key capture of `HotKeyRecorder`: a `KeyCaptureCoordinator` active while recording.
private struct KeyCapture: NSViewRepresentable {
    var isActive: Bool
    var onKey: @MainActor (UInt16, UInt) -> Void
    var onResignKey: @MainActor () -> Void
    var onRecording: @MainActor (Bool) -> Void

    func makeCoordinator() -> KeyCaptureCoordinator { KeyCaptureCoordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.onKey = onKey
        c.onResignKey = onResignKey
        c.onRecording = onRecording
        c.setActive(isActive)
    }

    static func dismantleNSView(_ view: NSView, coordinator: KeyCaptureCoordinator) {
        coordinator.teardown()
    }
}

/// While active: a local `keyDown` monitor that captures (and swallows) key events aimed at the view's window,
/// and an observer that reports the window resigning key. Each activation change is reported to `onRecording`.
@MainActor final class KeyCaptureCoordinator {
    weak var view: NSView?
    var onKey: (@MainActor (UInt16, UInt) -> Void)?
    var onResignKey: (@MainActor () -> Void)?
    var onRecording: (@MainActor (Bool) -> Void)?
    private(set) var isActive = false
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?

    /// Only events for the recorder's own window; other windows keep their keys.
    nonisolated static func accepts(eventWindow: NSWindow?, viewWindow: NSWindow?) -> Bool {
        guard let viewWindow else { return false }
        return eventWindow === viewWindow
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let window = event.window
                let keyCode = event.keyCode
                let flags = event.modifierFlags.rawValue
                let captured = MainActor.assumeIsolated { () -> Bool in
                    guard let self, Self.accepts(eventWindow: window, viewWindow: self.view?.window) else { return false }
                    self.onKey?(keyCode, flags)
                    return true
                }
                return captured ? nil : event                   // swallow: recording owns this window's keys
            }
            if let window = view?.window {
                resignObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onResignKey?() }
                }
            }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
        }
        onRecording?(active)
    }

    /// The view is going away: stop capturing (reports the stop when it was recording).
    func teardown() { setActive(false) }
}
