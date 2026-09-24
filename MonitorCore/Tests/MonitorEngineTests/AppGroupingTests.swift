import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

private let me: uid_t = 501

private func raw(_ pid: Int32, path: String?, uid: UInt32 = 501, comm: String = "proc", responsible: Int32? = nil,
                 restricted: Bool = false) -> RawProcess {
    RawProcess(id: ProcessID(pid: pid, startTimeUs: 1_000), uid: uid, comm: comm, path: path, responsiblePID: responsible,
               restricted: restricted)
}

@Suite struct AppGroupingTests {
    // MARK: BundleAppResolver (ARCHITECTURE §5.1 rules 1–4)

    @Test func appBundleByBundleID() throws {
        let b = try FakeBundles()
        let exe = try b.app("Final Cut Pro", bundleID: "com.apple.FinalCut", displayName: "Final Cut Pro", name: "FCP")
        let r = BundleAppResolver(currentUID: me)
        let id = r.identity(for: raw(10, path: exe), responsible: nil)
        #expect(id.key == AppKey(kind: .app, id: "com.apple.FinalCut"))
        #expect(id.displayName == "Final Cut Pro")
        #expect(id.bundlePath == b.path("Final Cut Pro.app"))
    }

    @Test func nameFallsBackToBundleNameThenFilename() throws {
        let b = try FakeBundles()
        let r = BundleAppResolver(currentUID: me)
        let named = try b.app("A", bundleID: "x.a", name: "Alpha")
        #expect(r.identity(for: raw(1, path: named), responsible: nil).displayName == "Alpha")
        let bare = try b.app("Bare Thing", bundleID: nil)
        let id = r.identity(for: raw(2, path: bare), responsible: nil)
        #expect(id.displayName == "Bare Thing")
        #expect(id.key == AppKey(kind: .app, id: b.path("Bare Thing.app")))     // no bundle id → bundle path
    }

    @Test func helperInsideNestedAppGroupsUnderOutermostApp() throws {
        let b = try FakeBundles()
        try b.app("Arc", bundleID: "company.thebrowser.Browser", displayName: "Arc")
        let helper = try b.app("Arc.app/Contents/Frameworks/Browser Helper", bundleID: "company.thebrowser.helper")
        let r = BundleAppResolver(currentUID: me)
        #expect(r.identity(for: raw(3, path: helper), responsible: nil).key == AppKey(kind: .app, id: "company.thebrowser.Browser"))
    }

    @Test func responsiblePIDDecides() throws {
        let b = try FakeBundles()
        let docker = try b.app("Docker", bundleID: "com.docker.docker", displayName: "Docker Desktop")
        let r = BundleAppResolver(currentUID: me)
        let backend = raw(20, path: "/usr/local/bin/com.docker.backend", responsible: 19)
        let id = r.identity(for: backend, responsible: raw(19, path: docker))
        #expect(id.displayName == "Docker Desktop")
    }

    @Test func userNonBundleExecutableIsOwnProcessGroup() {
        let r = BundleAppResolver(currentUID: me)
        let id = r.identity(for: raw(30, path: "/Users/me/.nvm/bin/node", comm: "node"), responsible: nil)
        #expect(id.key == AppKey(kind: .process, id: "/Users/me/.nvm/bin/node"))
        #expect(id.displayName == "node")
        #expect(id.bundlePath == nil)
    }

    @Test func userProcessWithoutPathUsesComm() {
        let r = BundleAppResolver(currentUID: me)
        let id = r.identity(for: raw(31, path: nil, comm: "zsh"), responsible: nil)
        #expect(id.key == AppKey(kind: .process, id: "zsh"))
        #expect(id.displayName == "zsh")
    }

    @Test(arguments: [
        ("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", "WindowServer"),
        ("/usr/libexec/trustd", "trustd"), ("/sbin/launchd", "launchd"), ("/usr/local/bin/node", "node"),
        ("/opt/homebrew/bin/postgres", "postgres"),
    ])
    func bundleLessDaemonsOfAnyUIDAreOwnProcessGroups(_ path: String, _ name: String) {
        let r = BundleAppResolver(currentUID: me)
        for uid: UInt32 in [0, 501, 88] {
            let id = r.identity(for: raw(40 + Int32(uid), path: path, uid: uid, restricted: uid != 501), responsible: nil)
            #expect(id.key == AppKey(kind: .process, id: path))
            #expect(id.displayName == name)
        }
    }

    @Test func usrLocalNodeGetsItsOwnGroup() {
        let r = BundleAppResolver(currentUID: me)
        let a = r.identity(for: raw(41, path: "/usr/local/bin/node", comm: "node"), responsible: nil)
        let b = r.identity(for: raw(42, path: "/usr/libexec/trustd"), responsible: nil)
        #expect(a.key == AppKey(kind: .process, id: "/usr/local/bin/node"))
        #expect(a.key != b.key)
    }

    @Test func noPathNoNameIsSystem() {
        let r = BundleAppResolver(currentUID: me)
        let id = r.identity(for: raw(43, path: nil, uid: 0, comm: "", restricted: true), responsible: nil)
        #expect(id.key == .system)
        #expect(id.displayName == "System")
    }

    @Test func unreadableResponsiblePathUsesItsCommNeverChildPath() throws {
        let b = try FakeBundles()
        let childExe = try b.app("Child", bundleID: "com.x.child")
        let r = BundleAppResolver(currentUID: me)
        let parent = raw(90, path: nil, uid: 0, comm: "launchd_helper", restricted: true)
        let id = r.identity(for: raw(91, path: childExe, responsible: 90), responsible: parent)
        #expect(id.key == AppKey(kind: .process, id: "launchd_helper"))
        // a later sibling under the same responsible pid must not see a cache poisoned by a child's path
        let sibling = r.identity(for: raw(92, path: "/usr/bin/other", responsible: 90), responsible: parent)
        #expect(sibling == id)
    }

    @Test func restrictedChildWithKnownResponsibleGroupsUnderIt() throws {
        let b = try FakeBundles()
        let app = try b.app("Docker", bundleID: "com.docker.docker", displayName: "Docker Desktop")
        let r = BundleAppResolver(currentUID: me)
        let child = raw(95, path: "/Library/PrivilegedHelperTools/com.docker.vmnetd", uid: 0, responsible: 94,
                        restricted: true)
        #expect(r.identity(for: child, responsible: raw(94, path: app)).displayName == "Docker Desktop")
    }

    @Test func otherUserInsideAppBundleStillGroupsByApp() throws {
        let b = try FakeBundles()
        let exe = try b.app("Daemonized", bundleID: "com.x.daemon", displayName: "Daemonized")
        let r = BundleAppResolver(currentUID: me)
        #expect(r.identity(for: raw(50, path: exe, uid: 0, restricted: true), responsible: nil).key.kind == .app)
    }

    @Test func restrictedWithoutPathUsesComm() {
        let r = BundleAppResolver(currentUID: me)
        let id = r.identity(for: raw(60, path: nil, uid: 0, comm: "kernel_task", restricted: true), responsible: nil)
        #expect(id.key == AppKey(kind: .process, id: "kernel_task"))
        #expect(id.displayName == "kernel_task")
    }

    @Test func cacheHitDoesNotTouchDisk() throws {
        let b = try FakeBundles()
        let exe = try b.app("Cached", bundleID: "com.x.cached", displayName: "Cached")
        let reads = ReadCounter()
        let r = BundleAppResolver(currentUID: me, readInfoPlist: { reads.count += 1; return BundleAppResolver.readInfoPlist($0) })
        let first = r.identity(for: raw(70, path: exe), responsible: nil)
        try b.remove("Cached")                                           // disk gone: must be served from cache
        #expect(r.identity(for: raw(70, path: exe), responsible: nil) == first)
        let sibling = r.identity(for: raw(71, path: exe), responsible: nil) // other pid, same bundle: bundle cache
        #expect(sibling == first)
        #expect(reads.count == 1)
    }

    @Test func pruneForgetsDeadProcesses() throws {
        let b = try FakeBundles()
        let exe = try b.app("P", bundleID: "com.x.p")
        let reads = ReadCounter()
        let r = BundleAppResolver(currentUID: me, readInfoPlist: { reads.count += 1; return BundleAppResolver.readInfoPlist($0) })
        let p80 = raw(80, path: exe), p81 = raw(81, path: exe)
        _ = r.identity(for: p80, responsible: nil)
        _ = r.identity(for: p81, responsible: nil)
        r.prune(keeping: [p81.id])
        #expect(r.cachedProcessCount == 1)
        #expect(r.cachedBundleCount == 1)                                // still referenced by 81
        r.prune(keeping: [])
        #expect(r.cachedProcessCount == 0)
        #expect(r.cachedBundleCount == 0)
        _ = r.identity(for: p80, responsible: nil)
        #expect(reads.count == 2)                                        // re-read after the bundle entry was pruned
    }

    // MARK: FixtureAppResolver

    @Test func fixtureResolverMapsResponsiblePID() {
        let chrome = AppIdentity(key: AppKey(kind: .app, id: "com.google.Chrome"), displayName: "Chrome")
        let r = FixtureAppResolver([100: chrome])
        #expect(r.identity(for: raw(101, path: nil, responsible: 100), responsible: raw(100, path: nil)) == chrome)
        #expect(r.identity(for: raw(100, path: nil), responsible: nil) == chrome)
        #expect(r.identity(for: raw(5, path: nil), responsible: nil).key == .system)
    }

    // MARK: AppGrouper

    @Test func groupsSumsAndSorts() {
        let a = AppKey(kind: .app, id: "a"), b = AppKey(kind: .app, id: "b")
        let procs = [
            ProcessSample(id: ProcessID(pid: 1, startTimeUs: 1), isCurrentUser: true, app: a, cpuPercent: 10, threads: 2,
                          memory: 100, netRxBps: 5, energyWatts: 1),
            ProcessSample(id: ProcessID(pid: 2, startTimeUs: 1), isCurrentUser: true, app: a, cpuPercent: 30, threads: 3,
                          memory: 50, energyWatts: 0.5, energyEstimated: true, preventsSleep: true),
            ProcessSample(id: ProcessID(pid: 3, startTimeUs: 1), app: b, cpuPercent: 99),
        ]
        let apps = AppGrouper.group(procs, identities: [a: AppIdentity(key: a, displayName: "Alpha")])
        #expect(apps.map(\.identity.key) == [b, a])                      // cpu desc
        let alpha = apps[1]
        #expect(alpha.identity.displayName == "Alpha")
        #expect(alpha.processIDs == [ProcessID(pid: 1, startTimeUs: 1), ProcessID(pid: 2, startTimeUs: 1)])
        #expect(alpha.cpuPercent == 40)
        #expect(alpha.memory == 150)
        #expect(alpha.netRxBps == 5)
        #expect(alpha.netTxBps == nil)                                   // nobody has it → nil, not 0
        #expect(alpha.gpuPercent == nil)
        #expect(alpha.energyWatts == 1.5)
        #expect(alpha.energyEstimated)
        #expect(alpha.threads == 5)
        #expect(alpha.preventsSleep)
        #expect(alpha.isCurrentUser)
        #expect(alpha.metrics[.cpu] == 40)
        #expect(apps[0].identity.displayName == "b")                     // missing identity → key id
    }

    @Test func restrictedAndSyntheticRows() {
        let sys = AppKey.system
        let procs = [
            ProcessSample(id: ProcessID(pid: 418, startTimeUs: 1), app: sys, provenance: .restricted, coalitionID: 7),
            ProcessSample(id: ProcessID(pid: 419, startTimeUs: 1), app: sys, provenance: .restricted, coalitionID: 7),
            ProcessSample(id: .coalitionResidual(7), name: "WindowServer", app: sys, provenance: .coalition,
                          coalitionID: 7, cpuPercent: 55, diskWriteBps: 10, energyWatts: 0.2, energyEstimated: true),
            ProcessSample(id: ProcessID(pid: 1, startTimeUs: 1), app: sys, provenance: .coalition, cpuPercent: 5),
        ]
        let app = AppGrouper.group(procs, identities: [:])[0]
        #expect(app.identity.displayName == "System")
        #expect(app.hiddenProcessCount == 2)
        #expect(app.processIDs.count == 3)                               // synthetic id excluded
        #expect(app.cpuPercent == 60)
        #expect(app.coalitionResidual?[.cpu] == 55)
        #expect(app.coalitionResidual?[.diskWrite] == 10)
        #expect(app.coalitionResidual?[.energy] == 0.2)
        #expect(app.coalitionResidual?[.memory] == nil)
    }

    @Test func unattributedUsageGoesToSystem() {
        let a = AppKey(kind: .app, id: "a")
        let procs = [ProcessSample(id: ProcessID(pid: 1), app: a, cpuPercent: 1, gpuPercent: 2)]
        let un = UnattributedUsage(gpuPercent: 7, netRxBps: 100, netTxBps: nil)
        let apps = AppGrouper.group(procs, identities: [:], unattributed: un)
        let sys = apps.first { $0.identity.key == .system }
        #expect(sys != nil)                                              // created although no process maps to it
        #expect(sys?.identity.displayName == "System")
        #expect(sys?.gpuPercent == 7)
        #expect(sys?.netRxBps == 100)
        #expect(sys?.netTxBps == nil)
        #expect(sys?.metrics[.gpu] == 7)
        #expect(apps.first { $0.identity.key == a }?.gpuPercent == 2)

        let withSys = AppGrouper.group(procs + [ProcessSample(id: ProcessID(pid: 2), app: .system, gpuPercent: 1)],
                                       identities: [:], unattributed: un)
        #expect(withSys.filter { $0.identity.key == .system }.count == 1)
        #expect(withSys.first { $0.identity.key == .system }?.gpuPercent == 8)
    }

    @Test func emptyUnattributedAddsNoSystemRow() {
        let apps = AppGrouper.group([ProcessSample(id: ProcessID(pid: 1), app: AppKey(kind: .app, id: "a"))],
                                    identities: [:], unattributed: UnattributedUsage())
        #expect(apps.count == 1)
    }

    @Test func noSyntheticRowsMeansNoResidual() {
        let apps = AppGrouper.group([ProcessSample(id: ProcessID(pid: 1), app: .system, cpuPercent: 1)], identities: [:])
        #expect(apps[0].coalitionResidual == nil)
    }
}

final class ReadCounter { var count = 0 }
