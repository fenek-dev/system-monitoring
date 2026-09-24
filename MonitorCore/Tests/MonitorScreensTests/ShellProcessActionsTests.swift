import Darwin
import Foundation
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("Shell process actions (ProcessActionsTests)", .serialized) @MainActor
struct ShellProcessActionsTests {
    private func spawn(_ path: String = "/bin/sleep", _ args: [String] = ["100"]) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        return p
    }

    private func waitExit(_ p: Process, timeout: Duration = .seconds(3)) async -> Bool {
        let end = ContinuousClock.now + timeout
        while p.isRunning, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
        return !p.isRunning
    }

    private func id(_ p: Process) -> ProcessID {
        ProcessID(pid: p.processIdentifier, startTimeUs: ProcessActionsLive.liveStartTimeUs(p.processIdentifier) ?? 0)
    }

    private func target(_ id: ProcessID) -> ProcessTarget {
        .process(id, name: "sleep", path: "/bin/sleep", uid: getuid())
    }

    private func app(_ ids: [ProcessID], key: AppKey = AppKey(kind: .app, id: "x")) -> ProcessTarget {
        .app(AppIdentity(key: key, displayName: "X"), processes: ids)
    }

    @Test func quitSendsSIGTERM() async throws {
        let p = try spawn()
        let actions = ProcessActionsLive.make()
        #expect(actions.canControl(target(id(p))))
        #expect(await actions.quit(target(id(p))) == .done)                 // gone within the wait → confirmed
        #expect(await waitExit(p))
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGTERM)
    }

    @Test func forceQuitSendsSIGKILL() async throws {
        let p = try spawn()
        let actions = ProcessActionsLive.make()
        #expect(await actions.forceQuit(target(id(p))) == .done)
        #expect(await waitExit(p))
        #expect(p.terminationReason == .uncaughtSignal && p.terminationStatus == SIGKILL)
    }

    /// A process that ignores SIGTERM is only "asked" to quit (`.requested`), never reported as quit.
    @Test func quitThatDoesNotFinishIsOnlyRequested() async throws {
        let p = try spawn("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 100"])
        defer { kill(p.processIdentifier, SIGKILL) }
        try await Task.sleep(for: .milliseconds(200))                        // let the trap + exec happen
        let actions = ProcessActionsLive.make(quitWait: .milliseconds(200))
        #expect(await actions.quit(target(id(p))) == .requested)
        #expect(p.isRunning)
    }

    /// I2: a pid whose start time no longer matches (reused) is never signalled.
    @Test func reusedPidIsNeverSignalled() async throws {
        let p = try spawn()
        defer { kill(p.processIdentifier, SIGKILL) }
        let live = id(p)
        #expect(live.startTimeUs != 0)
        let stale = ProcessID(pid: live.pid, startTimeUs: live.startTimeUs - 1_000_000)
        let actions = ProcessActionsLive.make()
        #expect(await actions.forceQuit(target(stale)) == .exited)
        #expect(await actions.quit(target(stale)) == .exited)
        #expect(await actions.forceQuit(app([stale])) == .exited)
        #expect(await actions.forceQuit(target(ProcessID(pid: live.pid))) == .exited)   // unknown start time
        try await Task.sleep(for: .milliseconds(50))
        #expect(p.isRunning)
    }

    @Test func exitedProcessReportsExited() async throws {
        let p = try spawn()
        let gone = id(p)
        kill(gone.pid, SIGKILL)
        #expect(await waitExit(p))
        let actions = ProcessActionsLive.make(owner: { _ in getuid() })     // owner check passes; start time fails
        #expect(await actions.forceQuit(target(gone)) == .exited)
    }

    /// Force Quit on a group kills every live member; a member that already exited is skipped.
    @Test func forceQuitGroupKillsEveryVerifiedMember() async throws {
        let a = try spawn(), b = try spawn(), c = try spawn()
        let gone = id(c)
        kill(gone.pid, SIGKILL)
        #expect(await waitExit(c))
        let actions = ProcessActionsLive.make(owner: { _ in getuid() })
        #expect(await actions.forceQuit(app([id(a), gone, id(b)])) == .done)
        #expect(await waitExit(a))
        #expect(await waitExit(b))
    }

    /// I1: Telltale's own process is never controllable, so the service never signals it.
    @Test func selfIsNeverControllable() async {
        let me = ProcessID(pid: getpid(), startTimeUs: ProcessActionsLive.liveStartTimeUs(getpid()) ?? 0)
        let actions = ProcessActionsLive.make()
        #expect(!actions.canControl(target(me)))
        #expect(await actions.forceQuit(target(me)) == .notPermitted)
        #expect(await actions.quit(app([me])) == .notPermitted)
        let uid = getuid()
        let own = app([ProcessID(pid: 700, startTimeUs: 1)], key: AppKey(kind: .app, id: "dev.telltale.Telltale"))
        #expect(!ProcessActionsLive.canControl(own, uid: uid, owner: { _ in uid }, ownBundleID: "dev.telltale.Telltale"))
        #expect(ProcessActionsLive.canControl(own, uid: uid, owner: { _ in uid }, ownBundleID: "other"))
    }

    /// A-I3 ruling: graceful Quit on a group asks only the app (regular-app members); a bundle-less group gets its
    /// leader (earliest-started member) only; Force Quit takes every member.
    @Test func quitRecipients() {
        let leader = ProcessID(pid: 900, startTimeUs: 10)
        let helper = ProcessID(pid: 400, startTimeUs: 20)
        let other = ProcessID(pid: 500, startTimeUs: 30)
        let group = app([helper, leader, other])
        #expect(ProcessActionsLive.recipients(group, force: false, isRegularApp: { $0 == 500 }) == [other])
        #expect(ProcessActionsLive.recipients(group, force: false, isRegularApp: { _ in false }) == [leader])
        #expect(ProcessActionsLive.recipients(group, force: true, isRegularApp: { $0 == 500 }) == [helper, leader, other])
        #expect(ProcessActionsLive.recipients(target(helper), force: false, isRegularApp: { _ in false }) == [helper])
        #expect(ProcessActionsLive.recipients(app([]), force: false, isRegularApp: { _ in false }).isEmpty)
    }

    @Test func launchdRootAndSyntheticAreNotControllable() async {
        let actions = ProcessActionsLive.make()
        let launchd = ProcessTarget.process(ProcessID(pid: 1), name: "launchd", path: "/sbin/launchd", uid: 0)
        #expect(!actions.canControl(launchd))
        #expect(await actions.quit(launchd) == .notPermitted)
        #expect(!actions.canControl(.process(ProcessID(pid: -7), name: "coalition", path: nil, uid: getuid())))
        #expect(!actions.canControl(.app(AppIdentity(key: .system, displayName: "System"), processes: [])))
    }

    @Test func otherUsersPidsAreNotControllable() {
        let uid = getuid()
        let owner: (Int32) -> uid_t? = { $0 == 500 ? 0 : uid }            // pid 500 "belongs to root"
        let mixed = app([ProcessID(pid: 400), ProcessID(pid: 500)])
        #expect(!ProcessActionsLive.canControl(mixed, uid: uid, owner: owner))
        let mine = app([ProcessID(pid: 400), ProcessID(pid: 401)])
        #expect(ProcessActionsLive.canControl(mine, uid: uid, owner: owner))
        #expect(!ProcessActionsLive.canControl(.process(ProcessID(pid: 400), name: "x", path: nil, uid: 0),
                                               uid: uid, owner: owner))
        #expect(!ProcessActionsLive.canControl(mine, uid: uid, owner: { _ in nil }))       // gone
    }

    @Test func ownerUIDAndStartTimeOfSelf() {
        #expect(ProcessActionsLive.ownerUID(getpid()) == getuid())
        #expect(ProcessActionsLive.ownerUID(1) == 0)
        #expect(ProcessActionsLive.liveStartTimeUs(getpid()) == LiveProcessSampler().startTimeUs(pid: getpid()))
        #expect(ProcessActionsLive.liveStartTimeUs(-5) == nil)
    }
}
