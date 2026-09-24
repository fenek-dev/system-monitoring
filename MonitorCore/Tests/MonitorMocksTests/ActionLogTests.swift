import Foundation
import Testing
import MonitorModel
@testable import MonitorMocks

@Suite struct ActionLogTests {
    static let userApp = ProcessTarget.app(
        AppIdentity(key: AppKey(kind: .app, id: "com.apple.dt.Xcode"), displayName: "Xcode"), pids: [1_842])
    static let systemDaemon = ProcessTarget.app(
        AppIdentity(key: AppKey(kind: .process, id: "WindowServer"), displayName: "WindowServer"), pids: [210])
    static let ownedProcess = ProcessTarget.process(pid: 1_842, name: "Xcode", path: nil, uid: 501)
    static let rootProcess = ProcessTarget.process(pid: 210, name: "WindowServer", path: nil, uid: 0)

    @MainActor
    @Test func canControlMatchesOwnership() {
        let actions = MockDataProvider(scenario: .calm).processActions(log: ActionLog())
        #expect(actions.canControl(Self.userApp))
        #expect(!actions.canControl(Self.systemDaemon))
        #expect(actions.canControl(Self.ownedProcess))
        #expect(!actions.canControl(Self.rootProcess))
    }

    @MainActor
    @Test func quittingAnOwnedAppSucceedsAndIsRecorded() async {
        let log = ActionLog()
        let actions = MockDataProvider(scenario: .calm).processActions(log: log)
        let result = await actions.quit(Self.userApp)
        #expect(result == .done)
        #expect(log.records.last == ActionLog.Entry(kind: .quit, targetName: "Xcode", result: .done, at: log.records.last!.at))
    }

    @MainActor
    @Test func forceQuittingASystemDaemonIsNotPermitted() async {
        let log = ActionLog()
        let actions = MockDataProvider(scenario: .calm).processActions(log: log)
        let result = await actions.forceQuit(Self.systemDaemon)
        #expect(result == .notPermitted)
        #expect(log.records.last?.result == .notPermitted)
        #expect(log.records.last?.kind == .forceQuit)
    }

    @MainActor
    @Test func revealAndActivityMonitorAlwaysRecordDone() {
        let log = ActionLog()
        let actions = MockDataProvider(scenario: .calm).processActions(log: log)
        actions.revealInFinder(Self.systemDaemon)
        actions.openInActivityMonitor(Self.userApp)
        #expect(log.records.map(\.kind) == [.revealInFinder, .openInActivityMonitor])
        #expect(log.records.allSatisfy { $0.result == .done })
    }

    @MainActor
    @Test func ejectRespectsEjectability() async {
        let log = ActionLog()
        let actions = MockDataProvider(scenario: .calm).processActions(log: log)
        let ejectable = VolumeInfo(id: "/Volumes/Backup", name: "Backup", isEjectable: true)
        let internalDisk = VolumeInfo(id: "/", name: "Macintosh HD", isEjectable: false)

        #expect(await actions.eject(ejectable) == .done)
        #expect(await actions.eject(internalDisk) == .notPermitted)
        #expect(log.entries.count == 2)
    }

    @Test func entriesAreOrderedAndClearWipesThem() {
        let log = ActionLog()
        log.record(.quit, target: "A", result: .done)
        log.record(.quit, target: "B", result: .notPermitted)
        #expect(log.entries == ["quit A -> done", "quit B -> notPermitted"])
        log.clear()
        #expect(log.records.isEmpty)
    }
}
