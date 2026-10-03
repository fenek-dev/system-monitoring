import Foundation
import Testing
@testable import MonitorExtraDim

/// One display's live table (starts at `colorSync`); reads and writes can be made to fail.
@MainActor
final class FakeGammaDevice: GammaDevice {
    static let colorSync = GammaTable(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])
    var live = FakeGammaDevice.colorSync
    var failWrites = false
    var failReads = false

    func readTable(_ display: UInt32) -> GammaTable? { failReads ? nil : live }
    func writeTable(_ table: GammaTable, to display: UInt32) -> Bool {
        guard !failWrites else { return false }
        live = table
        return true
    }
}

@Suite @MainActor struct GammaSessionTests {
    @Test func applyAndRestoreRoundTrip() {
        let d = FakeGammaDevice()
        let s = GammaSession(device: d)
        #expect(s.captureBase(1))
        #expect(s.apply(level: 4))
        #expect(d.live == FakeGammaDevice.colorSync.dimmed(level: 4))
        #expect(s.drift(level: 4) == .none)
        #expect(s.restore())
        #expect(d.live == FakeGammaDevice.colorSync)
        #expect(s.base == nil)
    }

    /// Finding: a failed restore must keep the base so the dimmed display can still be recovered.
    @Test func failedRestoreKeepsBaseForRetry() {
        let d = FakeGammaDevice()
        let s = GammaSession(device: d)
        _ = s.captureBase(1)
        _ = s.apply(level: 8)
        d.failWrites = true
        #expect(!s.restore())
        #expect(s.restorePending)
        #expect(s.base == FakeGammaDevice.colorSync)
        #expect(s.display == 1)
        d.failWrites = false
        #expect(s.restore())
        #expect(!s.restorePending)
        #expect(d.live == FakeGammaDevice.colorSync)
        #expect(s.base == nil)
    }

    /// Finding: recapturing after a failed restore must not take the dimmed table as the new base (no compounding).
    @Test func recaptureAfterFailedRestoreRecoversFirst() {
        let d = FakeGammaDevice()
        let s = GammaSession(device: d)
        _ = s.captureBase(1)
        _ = s.apply(level: 8)
        d.failWrites = true
        _ = s.restore()
        d.failWrites = false
        #expect(s.captureBase(1))
        #expect(s.base == FakeGammaDevice.colorSync)
        #expect(!s.restorePending)
    }

    /// Finding (round 2): no global ColorSync fallback; while the restore keeps failing, recapture is refused and
    /// the kept base is never replaced by the dimmed table.
    @Test func recaptureRefusedWhileRestoreStillFails() {
        let d = FakeGammaDevice()
        let s = GammaSession(device: d)
        _ = s.captureBase(1)
        _ = s.apply(level: 8)
        d.failWrites = true
        _ = s.restore()
        #expect(!s.captureBase(1))
        #expect(s.base == FakeGammaDevice.colorSync)
        #expect(s.restorePending)
        #expect(!s.apply(level: 1))
        #expect(s.drift(level: 1) == .unreadable)
    }

    @Test func driftAndUnreadable() {
        let d = FakeGammaDevice()
        let s = GammaSession(device: d)
        #expect(s.drift(level: 1) == .unreadable)        // no base
        _ = s.captureBase(1)
        _ = s.apply(level: 2)
        d.live = FakeGammaDevice.colorSync                 // another app wrote the table
        #expect(s.drift(level: 2) == .drifted)
        d.failReads = true
        #expect(s.drift(level: 2) == .unreadable)
    }

    @Test func captureFailsWhenUnreadable() {
        let d = FakeGammaDevice()
        d.failReads = true
        let s = GammaSession(device: d)
        #expect(!s.captureBase(1))
        #expect(s.base == nil)
        #expect(!s.apply(level: 1))
    }
}
