import MonitorModel
import SwiftUI
import Testing
@testable import MonitorUIKit

/// Additive W3-file changes made by W5a (fix round 3, authorized): stat-strip detail tint, bits-aware rate ceiling.
@Suite struct W5aAdditionsTests {
    @Test func statStripDetailTintDefaultsToTertiary() {
        let plain = TTStatStrip.Item(id: "a", label: "Memory pressure", value: "38%", detail: "Normal")
        #expect(plain.detailTint == nil)
        #expect(plain.detailColor == TTColor.textTertiary)
        let warn = TTStatStrip.Item(id: "b", label: "Memory pressure", value: "71%", detail: "Warning",
                                    detailTint: TTColor.statusElevated)
        #expect(warn.detailColor == TTColor.statusElevated)
        #expect(plain != plain.with(detailTint: TTColor.statusElevated))   // Equatable includes the new field
    }

    @Test func niceRateCeilingInDisplayUnit() {
        var bits = UnitPreferences()
        bits.networkRate = .bits
        let bytes = UnitPreferences()
        // 4.2 MB/s = 33.6 Mbps → nice 40 Mbps = 5 MB/s.
        #expect(TTFormat.niceRateCeiling(4_200_000, units: bits) == 5_000_000)
        #expect(TTFormat.rateScale(TTFormat.niceRateCeiling(4_200_000, units: bits), units: bits) == "40 Mbps")
        #expect(TTFormat.niceRateCeiling(4_200_000, units: bytes) == 5_000_000)
        #expect(TTFormat.rateScale(TTFormat.niceRateCeiling(4_200_000, units: bytes), units: bytes) == "5 MB/s")
        // Bits minimum is 1 Mbps (125 KB/s), not 1 MB/s.
        #expect(TTFormat.niceRateCeiling(10_000, units: bits) == 125_000)
    }
}

private extension TTStatStrip.Item {
    func with(detailTint: Color?) -> Self {
        var c = self
        c.detailTint = detailTint
        return c
    }
}
