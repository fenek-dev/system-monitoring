import CoreGraphics
import MonitorExtraDim
import os

/// CoreGraphics gamma I/O behind `GammaSession` (extra-dim spec §4, §7), which owns the base/restore policy.
/// Screenshots and recordings bypass the gamma table, so they stay normal. Quartz restores ColorSync gamma when the
/// process exits, so a crash needs no handler. Every failure is logged here. Never calls the global
/// `CGDisplayRestoreColorSyncSettings` (it would reset other apps' tables on every display).
@MainActor
final class GammaDimmer: GammaDevice {
    private let log = Logger(subsystem: "dev.telltale", category: "ExtraDim")

    func readTable(_ display: UInt32) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(display)
        guard capacity > 0 else {
            log.error("gamma read failed on display \(display): no table capacity")
            return nil
        }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var size: UInt32 = 0
        let err = CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &size)
        guard err == .success, size > 0 else {
            log.error("gamma read failed on display \(display): \(err.rawValue) size \(size)")
            return nil
        }
        let n = Int(size)
        return GammaTable(red: Array(r.prefix(n)), green: Array(g.prefix(n)), blue: Array(b.prefix(n)))
    }

    func writeTable(_ table: GammaTable, to display: UInt32) -> Bool {
        let err = CGSetDisplayTransferByTable(display, UInt32(table.count), table.red, table.green, table.blue)
        if err != .success { log.error("gamma write failed on display \(display): \(err.rawValue)") }
        return err == .success
    }
}
