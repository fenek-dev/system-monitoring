import Darwin
import Foundation
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("Shell process actions (ProcessActionsTests)", .serialized) @MainActor
struct ShellProcessActionsTests {
    private func spawnSleep() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["100"]
        try p.run()
        return p
    }

    private func waitExit(_ p: Process, timeout: Duration = .seconds(3)) async -> Bool {
        let end = ContinuousClock.now + timeout
        while p.isRunning, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        return !p.isRunning
    }

    private func target(_ p: Process) -> ProcessTarget {
        .process(pid: p.processIdentifier, name: "sleep", path: "/bin/sleep", uid: getuid())
    }

    @Test func quitSendsSIGTERM() async throws {
        let p = try spawnSleep()
        let actions = ProcessActionsLive.make()
        #expect(actions.canControl(target(p)))
        #expect(await actions.quit(target(p)) == .done)
        #expect(await waitExit(p))
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM)
    }

    @Test func forceQuitSendsSIGKILL() async throws {
        let p = try spawnSleep()
        let actions = ProcessActionsLive.make()
        #expect(await actions.forceQuit(target(p)) == .done)
        #expect(await waitExit(p))
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL)
    }

    @Test func launchdRootAndSyntheticAreNotControllable() async {
        let actions = ProcessActionsLive.make()
        let launchd = ProcessTarget.process(pid: 1, name: "launchd", path: "/sbin/launchd", uid: 0)
        #expect(!actions.canControl(launchd))
        #expect(await actions.quit(launchd) == .notPermitted)
        #expect(!actions.canControl(.process(pid: -7, name: "coalition", path: nil, uid: getuid())))
        #expect(!actions.canControl(.app(AppIdentity(key: .system, displayName: "System"), pids: [])))
    }

    @Test func otherUsersPidsAreNotControllable() {
        let uid = getuid()
        let owner: (Int32) -> uid_t? = { $0 == 500 ? 0 : uid }            // pid 500 "belongs to root"
        let app = ProcessTarget.app(AppIdentity(key: AppKey(kind: .app, id: "x"), displayName: "X"), pids: [400, 500])
        #expect(!ProcessActionsLive.canControl(app, uid: uid, owner: owner))
        let mine = ProcessTarget.app(AppIdentity(key: AppKey(kind: .app, id: "x"), displayName: "X"), pids: [400, 401])
        #expect(ProcessActionsLive.canControl(mine, uid: uid, owner: owner))
        #expect(!ProcessActionsLive.canControl(.process(pid: 400, name: "x", path: nil, uid: 0), uid: uid, owner: owner))
        #expect(!ProcessActionsLive.canControl(mine, uid: uid, owner: { _ in nil }))       // gone
    }

    @Test func ownerUIDOfSelf() {
        #expect(ProcessActionsLive.ownerUID(getpid()) == getuid())
        #expect(ProcessActionsLive.ownerUID(1) == 0)
    }
}
