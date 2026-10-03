import Foundation

/// Raw gamma I/O for one display (CoreGraphics in the app, a fake in tests). Display IDs are `CGDirectDisplayID`.
@MainActor
public protocol GammaDevice: AnyObject {
    func readTable(_ display: UInt32) -> GammaTable?
    func writeTable(_ table: GammaTable, to display: UInt32) -> Bool
}

/// Base capture / apply / restore policy for the built-in display (extra-dim spec §4, §5.4–5.6, §7).
///
/// The base is captured only at the 0→1 transition and every apply writes `base × m(level)` (idempotent). A failed
/// restore keeps the base (`restorePending`): later restores retry it (display events, the next capture), and a
/// capture is refused while it still fails — reading a still-dimmed table as the new base would compound the dim.
/// There is deliberately no global fallback (`CGDisplayRestoreColorSyncSettings` would reset every display,
/// clobbering other apps); at quit Quartz restores this process's gamma tables itself (spec §5.6).
@MainActor
public final class GammaSession {
    public enum Drift: Equatable, Sendable {
        case none
        /// The live table ≠ `base × m(level)`: another app wrote it.
        case drifted
        /// No base, or the live table could not be read (spec §7: treated as a gamma failure).
        case unreadable
    }

    private let device: GammaDevice
    public private(set) var display: UInt32?
    public private(set) var base: GammaTable?
    /// A restore failed and the display may still be dimmed; `base` is kept for the retry.
    public private(set) var restorePending = false

    public init(device: GammaDevice) {
        self.device = device
    }

    /// Reads the live table of `display` as the new base. A pending restore is retried first; while it still
    /// fails the capture is refused (false).
    public func captureBase(_ display: UInt32) -> Bool {
        if base != nil, !restore() { return false }
        guard let table = device.readTable(display), table.count > 0 else { return false }
        self.display = display
        base = table
        return true
    }

    /// Writes `base × m(level)`. False without a base, while a restore is pending, or when the write fails.
    public func apply(level: Int) -> Bool {
        guard let display, let base, !restorePending else { return false }
        return device.writeTable(base.dimmed(level: level), to: display)
    }

    /// Writes the base back; drops it only once that succeeded. True when nothing is left to restore.
    @discardableResult
    public func restore() -> Bool {
        guard let display, let base else { return true }
        guard device.writeTable(base, to: display) else {
            restorePending = true
            return false
        }
        self.base = nil
        self.display = nil
        restorePending = false
        return true
    }

    public func drift(level: Int) -> Drift {
        guard let display, let base, !restorePending, let live = device.readTable(display) else { return .unreadable }
        return live.matches(base.dimmed(level: level)) ? .none : .drifted
    }
}
