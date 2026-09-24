import Foundation
import MonitorLive
import MonitorModel
@testable import MonitorScreens
import MonitorUIKit
import Testing

@Suite("Shell confirm dialog host") @MainActor
struct ShellConfirmDialogTests {
    final class Log { var events: [String] = [] }

    private func request(_ name: String, _ log: Log) -> ConfirmDialogRequest {
        ConfirmDialogRequest(title: name, message: "m", confirmTitle: "Force Quit",
                             onConfirm: { log.events.append("\(name).confirm") },
                             onCancel: { log.events.append("\(name).cancel") })
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
        host.cancelAll()                                         // window closing
        #expect(host.current == nil && log.events == ["a.cancel", "b.cancel"])
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

    @Test func presenterOfAGoneWindowCancels() async {
        var host: ConfirmDialogHost? = ConfirmDialogHost()
        let p = host!.presenter
        host = nil
        #expect(await p.confirm(title: "t", message: "m", confirmTitle: "c") == false)
    }
}

@Suite("Shell sidebar values") @MainActor
struct ShellSidebarValueTests {
    @Test func memoryUsesHeadlineRuleAndDiskUsesAvailableCapacity() {
        let live = LiveModel.mock(.calm)
        let units = UnitPreferences()
        // §5.3 headline: 1 decimal GB (the card rule), never the 2-decimal detail form
        if let mem = Sidebar.value(for: .memory, live: live, units: units), mem.hasSuffix(" GB") {
            let number = mem.dropLast(3)
            #expect(number.split(separator: ".").last?.count ?? 0 <= 1, "\(mem)")
        }
        // Ruling CP2: available capacity (VolumeInfo.availableBytes), same format as the Disk page
        if let boot = live.disk.bootVolume {
            #expect(Sidebar.value(for: .disk, live: live, units: units)
                == "\(TTFormat.storage(boot.availableBytes, style: .capacity)) free")
        }
        #expect(Sidebar.value(for: .overview, live: live, units: units) == nil)
    }
}
