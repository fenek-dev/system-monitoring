import AppKit
import CoreGraphics
import MonitorExtraDim
import os

/// Active `CGEventTap` for the brightness keys (extra-dim spec §5.1–5.3, §7). They arrive as `NX_SYSDEFINED`
/// aux-control-button events (subtype 8): `data1` = key code << 16 | key state << 8 | repeat flag; key code 2 = up,
/// 3 = down; state 0xA = key-down, 0xB = key-up.
///
/// The run loop source is on the main run loop, so the callback runs on the MainActor. `onKeyDown` must only read
/// brightness and step the machine (gamma/HUD work is enqueued by the caller), keeping the tap far from its timeout.
/// A key-up is consumed iff its key-down was, so the system never sees half a press. Needs Accessibility trust.
@MainActor
final class BrightnessKeyTap {
    static let keyBrightnessUp = 2
    static let keyBrightnessDown = 3
    private static let systemDefinedType = CGEventType(rawValue: 14)!        // NX_SYSDEFINED
    private static let auxControlButtons: Int16 = 8                           // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    private let onKeyDown: @MainActor (ExtraDimMachine.Key) -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Whether the last key-down of each key code was consumed (adapter state, not machine state).
    private var consumedDown: [Int: Bool] = [:]
    private var disabledTimes: [Date] = []
    private let log = Logger(subsystem: "dev.telltale", category: "ExtraDim")

    /// Nil when the tap cannot be created (no Accessibility trust, or the system refused).
    init?(onKeyDown: @escaping @MainActor (ExtraDimMachine.Key) -> Bool) {
        self.onKeyDown = onKeyDown
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedType.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<BrightnessKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            let consume = MainActor.assumeIsolated { tap.consumes(type, event) }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return nil }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Must be called before release: the callback holds an unretained pointer to `self`.
    func invalidate() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// True → the event is swallowed.
    private func consumes(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenable(type)
            return false
        }
        guard type == Self.systemDefinedType, let ns = NSEvent(cgEvent: event),
              ns.subtype.rawValue == Self.auxControlButtons
        else { return false }
        let data = ns.data1
        let code = (data & 0xFFFF_0000) >> 16
        let state = (data & 0xFF00) >> 8
        guard code == Self.keyBrightnessUp || code == Self.keyBrightnessDown else { return false }
        switch state {
        case 0xA:                                                 // key-down (auto-repeat included)
            let consume = onKeyDown(code == Self.keyBrightnessUp ? .up : .down)
            consumedDown[code] = consume
            return consume
        case 0xB:                                                 // key-up: same fate as its key-down
            return consumedDown[code] ?? false
        default:
            return false
        }
    }

    /// Re-enable at once; more than 3 disables in 60 s → a warning (still re-enabled).
    private func reenable(_ type: CGEventType) {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        let now = Date()
        disabledTimes = disabledTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if disabledTimes.count > 3 {
            log.warning("brightness tap disabled \(self.disabledTimes.count) times in 60 s (type \(type.rawValue))")
        }
    }
}
