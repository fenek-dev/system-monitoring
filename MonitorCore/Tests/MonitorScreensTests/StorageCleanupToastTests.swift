import Foundation
import MonitorModel
@testable import MonitorScreens
import Testing

/// Fake clock for the toast timer: `sleep` parks until `fire()`, so no test waits on real time.
@MainActor
private final class SleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sleeps = 0

    func sleep() async {
        sleeps += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        let parked = waiters
        waiters = []
        for waiter in parked { waiter.resume() }
    }

    func waitForSleeps(_ count: Int) async {
        while sleeps < count { await Task.yield() }
    }
}

/// Toast lifetime and run bookkeeping; same suite as the flow tests so the `StorageCleanupTests` filter runs them.
extension StorageCleanupTests {
    private func controller(_ gate: SleepGate) -> CleanToastController {
        CleanToastController(sleep: { _ in
            await gate.sleep()
            try Task.checkCancellation()
        })
    }

    private func report(undo: Bool = true) -> CleanReport {
        CleanReport(trashedBytes: 300_000_000,
                    undo: undo ? UndoRecord(date: Date(timeIntervalSince1970: 0), entries: []) : nil)
    }

    /// Bug: opening Show cancelled the timer, the cancellation was swallowed and the toast dismissed, losing Undo.
    @Test func pinnedToastSurvivesItsOldTimerAndExpiresAfterUnpin() async {
        let gate = SleepGate()
        let toast = controller(gate)
        toast.runStateChanged(.init(running: false, report: report()))
        await gate.waitForSleeps(1)
        toast.setPinned(true)
        gate.fire()
        await toast.timer?.value
        #expect(toast.toast != nil)

        toast.setPinned(false)
        await gate.waitForSleeps(2)
        gate.fire()
        await toast.timer?.value
        #expect(toast.toast == nil)
    }

    /// Bug: an interrupted Undo/Empty Trash (no report) left the own-run mark set and swallowed the next clean's toast.
    @Test func interruptedOwnRunDoesNotSwallowNextToast() {
        let toast = controller(SleepGate())
        toast.ownRunStarted()
        toast.runStateChanged(.init(running: true, report: nil))
        toast.runStateChanged(.init(running: false, report: nil))
        toast.runStateChanged(.init(running: true, report: nil))
        toast.runStateChanged(.init(running: false, report: report()))
        #expect(toast.toast?.undoID != nil)
        #expect(toast.toast?.text == "Moved 300 MB to Trash")
    }

    /// Bug: the report of the Undo / Empty Trash the toast started itself shown as a clean result.
    @Test func ownRunReportIsNotToasted() {
        let toast = controller(SleepGate())
        toast.ownRunStarted()
        toast.runStateChanged(.init(running: true, report: nil))
        toast.runStateChanged(.init(running: false, report: report(undo: false)))
        #expect(toast.toast == nil)
    }
}
