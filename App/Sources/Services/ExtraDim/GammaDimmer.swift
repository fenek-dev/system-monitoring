import CoreGraphics
import MonitorExtraDim
import os

/// Captures, applies and restores the built-in display's gamma table (extra-dim spec §4, §5.4–5.5). The base is
/// captured only at the 0→1 transition; every apply writes `base × m(level)` (idempotent, never compounds).
/// Screenshots and recordings bypass the gamma table, so they stay normal. Quartz restores ColorSync gamma when the
/// process exits, so a crash needs no handler.
@MainActor
final class GammaDimmer {
    private let log = Logger(subsystem: "dev.telltale", category: "ExtraDim")
    private(set) var display: CGDirectDisplayID?
    private(set) var base: GammaTable?

    /// Reads the live table as the base. False (logged) on a CoreGraphics error.
    func captureBase(_ display: CGDirectDisplayID) -> Bool {
        guard let table = Self.read(display) else {
            log.error("gamma capture failed on display \(display)")
            return false
        }
        self.display = display
        base = table
        return true
    }

    /// Writes `base × m(level)`. False (logged) without a base or on a CoreGraphics error.
    func apply(level: Int) -> Bool {
        guard let display, let base else { return false }
        let err = Self.write(base.dimmed(level: level), to: display)
        if err != .success { log.error("gamma apply level \(level) failed: \(err.rawValue)") }
        return err == .success
    }

    /// Writes the base back and drops it. No base → nothing to do. A display that went away just fails silently.
    func restore() {
        defer {
            base = nil
            display = nil
        }
        guard let display, let base else { return }
        let err = Self.write(base, to: display)
        if err != .success { log.notice("gamma restore failed: \(err.rawValue)") }
    }

    /// True when the live table no longer matches `base × m(level)` (another app wrote it); nil when unreadable.
    func drifted(level: Int) -> Bool? {
        guard let display, let base, let live = Self.read(display) else { return nil }
        return !live.matches(base.dimmed(level: level))
    }

    static func read(_ display: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var size: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &size) == .success, size > 0 else { return nil }
        let n = Int(size)
        return GammaTable(red: Array(r.prefix(n)), green: Array(g.prefix(n)), blue: Array(b.prefix(n)))
    }

    static func write(_ table: GammaTable, to display: CGDirectDisplayID) -> CGError {
        CGSetDisplayTransferByTable(display, UInt32(table.count), table.red, table.green, table.blue)
    }
}
