import Foundation

/// Raw gamma I/O for one display (CoreGraphics in the app, a fake in tests). Display IDs are `CGDirectDisplayID`.
@MainActor
public protocol GammaDevice: AnyObject {
    func readTable(_ display: UInt32) -> GammaTable?
    func writeTable(_ table: GammaTable, to display: UInt32) -> Bool
    /// `CGDisplayRestoreColorSyncSettings`: every display back to its ColorSync table (last-resort recovery).
    func restoreColorSync()
}

/// Base capture / apply / restore policy for the built-in display (extra-dim spec §4, §5.4–5.5, §7).
///
/// The base is captured only at the 0→1 transition and every apply writes `base × m(level)` (idempotent). A failed
/// restore keeps the base, so the dimmed display stays recoverable: the next restore retries it, and a capture
/// never reads a still-dimmed table as its base — it retries the restore first and falls back to ColorSync, so the
/// dim can never compound across sessions.
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

    public init(device: GammaDevice) {
        self.device = device
    }

    /// Reads the live table of `display` as the new base. A base left over by a failed restore is recovered first.
    public func captureBase(_ display: UInt32) -> Bool {
        if base != nil { restore(fallback: true) }
        guard let table = device.readTable(display), table.count > 0 else { return false }
        self.display = display
        base = table
        return true
    }

    /// Writes `base × m(level)`. False without a base or when the write fails.
    public func apply(level: Int) -> Bool {
        guard let display, let base else { return false }
        return device.writeTable(base.dimmed(level: level), to: display)
    }

    /// Writes the base back; drops it only once that succeeded. True when nothing is left to restore.
    /// `fallback`: on failure restore ColorSync instead and drop the base (quit, recapture).
    @discardableResult
    public func restore(fallback: Bool = false) -> Bool {
        guard let display, let base else { return true }
        if device.writeTable(base, to: display) {
            drop()
            return true
        }
        guard fallback else { return false }
        device.restoreColorSync()
        drop()
        return true
    }

    public func drift(level: Int) -> Drift {
        guard let display, let base, let live = device.readTable(display) else { return .unreadable }
        return live.matches(base.dimmed(level: level)) ? .none : .drifted
    }

    private func drop() {
        base = nil
        display = nil
    }
}
