import AppKit
import Foundation
import MonitorLive
import MonitorModel
@testable import MonitorScreens
import MonitorUIKit
import SwiftUI
import Testing

/// `.idleMainActor`: `pageChangeInDashboardCancelsExactlyOnce` has a 5 s deadline and re-queues on the main actor
/// every turn; inside the initial main-queue backlog of a full run it gets only a few turns.
@Suite("Shell confirm dialog host", .serialized, .idleMainActor) @MainActor
struct ShellConfirmDialogTests {
    final class Log { var events: [String] = [] }

    private func request(_ name: String, _ log: Log, id: UUID = UUID()) -> ConfirmDialogRequest {
        ConfirmDialogRequest(id: id, title: name, message: "m", confirmTitle: "Force Quit",
                             onConfirm: { log.events.append("\(name).confirm") },
                             onCancel: { log.events.append("\(name).cancel") })
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    /// One layout + run-loop turn so SwiftUI delivers `onChange` (sync: `RunLoop.run` is unavailable in async).
    private func pump(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    @Test func presentConfirmCancel() {
        let host = ConfirmDialogHost()
        let log = Log()
        host.presenter(request("a", log))
        #expect(host.current?.title == "a")
        host.confirm()
        #expect(host.current == nil && log.events == ["a.confirm"])
        host.presenter(request("b", log))
        host.cancel()
        #expect(host.current == nil && log.events == ["a.confirm", "b.cancel"])
        host.confirm()                                           // nothing pending: no-op
        #expect(log.events.count == 2)
    }

    @Test func newRequestReplacesAndCancelsThePrevious() {
        let host = ConfirmDialogHost()
        let log = Log()
        host.present(request("a", log))
        host.present(request("b", log))
        #expect(host.current?.title == "b" && log.events == ["a.cancel"])
    }

    @Test func samePresentedRequestIsANoOp() {
        let host = ConfirmDialogHost()
        let log = Log()
        let r = request("a", log)
        host.present(r)
        host.present(r)                                          // e.g. a view re-running its action
        #expect(host.current?.id == r.id && log.events.isEmpty)
        host.confirm()
        #expect(log.events == ["a.confirm"])
    }

    @Test func windowCloseCancelsExactlyOnce() {
        let host = ConfirmDialogHost()
        let log = Log()
        host.present(request("a", log))
        host.cancelAll()                                         // DashboardWindowController.windowWillClose
        host.cancelAll()
        #expect(host.current == nil && log.events == ["a.cancel"])
    }

    @Test func cancelByIDOnlyTouchesThatRequest() {
        let host = ConfirmDialogHost()
        let log = Log()
        let a = request("a", log)
        host.present(a)
        host.cancel(id: UUID())                                  // stale id: ignored
        #expect(host.current?.id == a.id && log.events.isEmpty)
        host.cancel(id: a.id)
        #expect(host.current == nil && log.events == ["a.cancel"])
    }

    @Test func presenterIsStable() {
        let host = ConfirmDialogHost()
        let log = Log()
        let p1 = host.presenter, p2 = host.presenter
        p1(request("a", log))
        p2(request("b", log))
        #expect(host.current?.title == "b" && log.events == ["a.cancel"])
    }

    @Test func asyncConfirmResolvesExactlyOnce() async {
        let host = ConfirmDialogHost()
        let p = host.presenter
        async let yes = p.confirm(title: "Force Quit “Xcode”?", message: "m", confirmTitle: "Force Quit")
        while host.current == nil { await Task.yield() }
        host.confirm()
        #expect(await yes)

        async let no = p.confirm(title: "t", message: "m", confirmTitle: "c")
        while host.current == nil { await Task.yield() }
        host.cancelAll()
        #expect(await no == false)
    }

    @Test func cancellingTheAwaitingTaskDismissesTheDialog() async {
        let host = ConfirmDialogHost()
        let p = host.presenter
        let task = Task { @MainActor in await p.confirm(title: "t", message: "m", confirmTitle: "c") }
        while host.current == nil { await Task.yield() }
        task.cancel()
        #expect(await task.value == false)
        await settle()
        #expect(host.current == nil)
        // cancelled before it could present: returns false, never shows
        let early = Task { @MainActor () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await p.confirm(title: "t", message: "m", confirmTitle: "c")
        }
        #expect(await early.value == false)
        await settle()
        #expect(host.current == nil)
    }

    @Test func presenterOfAGoneWindowCancels() async {
        var host: ConfirmDialogHost? = ConfirmDialogHost()
        let p = host!.presenter
        host = nil
        #expect(await p.confirm(title: "t", message: "m", confirmTitle: "c") == false)
    }

    /// DashboardRoot cancels the pending dialog when the page changes (the dialog belongs to the asking page).
    @Test func pageChangeInDashboardCancelsExactlyOnce() async {
        let host = ConfirmDialogHost()
        let log = Log()
        let ctx = ScreenFixture.context(.calm, page: .processes)
        let view = NSHostingView(rootView: DashboardRoot(dialogs: host).telltaleEnvironment(ctx))
        view.frame = CGRect(origin: .zero, size: ScreenSize.dashboard)
        view.layoutSubtreeIfNeeded()
        host.present(request("forceQuit", log))
        ctx.navigation.page = .overview
        let end = ContinuousClock.now + .seconds(5)
        while log.events.isEmpty, ContinuousClock.now < end {
            pump(view)
            await Task.yield()
        }
        #expect(log.events == ["forceQuit.cancel"] && host.current == nil)
        _ = view
    }
}

@Suite("Shell sidebar values") @MainActor
struct ShellSidebarValueTests {
    @Test func memoryUsesHeadlineRule() throws {
        let live = LiveModel.mock(.calm)
        let mem = try #require(Sidebar.value(for: .memory, live: live, units: UnitPreferences()))
        #expect(mem == TTFormat.memory(live.memory.used, style: .headline))
        // §5.3 headline: 1 decimal GB, never the 2-decimal detail form
        let number = try #require(mem.split(separator: " ").first)
        #expect((number.split(separator: ".").last?.count ?? 0) <= 1, "\(mem)")
    }

    @Test func diskUsesAvailableCapacity() throws {
        let live = LiveModel.mock(.calm)
        let boot = try #require(live.disk.bootVolume)
        #expect(Sidebar.value(for: .disk, live: live, units: UnitPreferences())
            == "\(TTFormat.storage(boot.availableBytes, style: .capacity)) free")   // ruling CP2 (= Disk page)
        #expect(Sidebar.value(for: .overview, live: live, units: UnitPreferences()) == nil)
    }

    /// A live model whose boot volume has `available` free and a larger `important` (purgeable included).
    private func live(available: UInt64, important: UInt64) -> LiveModel {
        let boot = VolumeInfo(id: "/", name: "Macintosh HD", isInternal: true, totalBytes: 994_000_000_000,
                              availableBytes: available, availableImportantBytes: important)
        let m = LiveModel()
        m.apply(SystemFrame(disk: DiskSnapshot(volumes: [boot])))
        m.isPresenting = true
        return m
    }

    /// W5b report: sidebar "372.53 GB…" vs Disk page "382 GB". Cause: the old sidebar read
    /// `availableImportantBytes` (purgeable included) through `TTFormat.bytes` (binary, 2 decimals, memory detail
    /// rule), so 400 GB decimal became "372.53 GB" and overflowed the column. Both now use `ShellFormat.freeSpace`.
    @Test(arguments: [
        (UInt64(382_000_000_000), UInt64(400_000_000_000), "382 GB free"),
        (UInt64(1_090_000_000_000), UInt64(1_200_000_000_000), "1.09 TB free"),
        (UInt64(45_400_000_000), UInt64(45_400_000_000), "45 GB free"),
    ])
    func diskSidebarMatchesDiskPageFreeSpace(_ available: UInt64, _ important: UInt64, _ expected: String) throws {
        let m = live(available: available, important: important)
        let boot = try #require(m.disk.bootVolume)
        let sidebar = Sidebar.value(for: .disk, live: m, units: UnitPreferences())
        #expect(sidebar == expected)
        #expect(sidebar == ShellFormat.freeSpace(boot) + " free")              // the Disk page's formatter
        #expect(ShellFormat.freeSpace(boot) == TTFormat.storage(boot.availableBytes, style: .capacity))
        #expect((sidebar?.count ?? 0) <= 12)                                   // fits the trailing column
    }

    nonisolated static func summary(_ root: ScanRoot, _ bytes: UInt64?, _ provenance: SizeProvenance) -> StorageSummary {
        StorageSummary(root: root, scanDate: Date(timeIntervalSince1970: 0), reclaimableBytes: bytes,
                       provenance: provenance, trashBytes: nil)
    }

    /// Bug: stale or wrong sidebar value (estimate shown as exact, other roots shown as reclaimable).
    @Test(arguments: [
        (ShellSidebarValueTests.summary(.home("/h"), 14_200_000_000, .exact), "14 GB reclaimable"),
        (ShellSidebarValueTests.summary(.home("/h"), 14_200_000_000, .estimate), "≈14 GB reclaimable"),
        (ShellSidebarValueTests.summary(.home("/h"), nil, .exact), "382 GB free"),
        (ShellSidebarValueTests.summary(.home("/h"), 14_200_000_000, .unavailable), "382 GB free"),
        (ShellSidebarValueTests.summary(.folder("/f"), 14_200_000_000, .exact), "382 GB free"),
    ] as [(StorageSummary, String)])
    func storageValue(_ summary: StorageSummary, _ expected: String) {
        let m = live(available: 382_000_000_000, important: 400_000_000_000)
        #expect(Sidebar.value(for: .storage, live: m, units: UnitPreferences(), storage: summary) == expected)
    }

    @Test func storageWithoutSummaryShowsFreeSpace() {
        let m = live(available: 382_000_000_000, important: 400_000_000_000)
        #expect(Sidebar.value(for: .storage, live: m, units: UnitPreferences()) == "382 GB free")
    }

    @Test func diskWithoutBootVolumeIsUnavailable() {
        let live = LiveModel()                                   // no frames: no volumes
        live.isPresenting = true
        #expect(live.disk.bootVolume == nil)
        #expect(Sidebar.value(for: .disk, live: live, units: UnitPreferences()) == "—")
    }
}
