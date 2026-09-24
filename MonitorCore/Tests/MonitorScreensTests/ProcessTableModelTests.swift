import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import Testing

/// Builders for small, hand-made process tables.
enum PT {
    static let me: UInt32 = 501

    static func proc(_ pid: Int32, _ name: String, app: AppKey, cpu: Double? = nil, gpu: Double? = nil,
                     mem: UInt64? = nil, rx: Double? = nil, tx: Double? = nil, read: Double? = nil,
                     write: Double? = nil, watts: Double? = nil, user: String = "arthur", uid: UInt32 = me,
                     path: String? = nil, provenance: Provenance = .measured, coalition: UInt64? = nil,
                     leader: String? = nil, threads: Int32? = 4) -> ProcessSample {
        ProcessSample(id: pid < 0 ? .coalitionResidual(coalition ?? 0) : ProcessID(pid: pid, startTimeUs: 1),
                      name: name, path: path, user: user, uid: uid, isCurrentUser: uid == me, app: app,
                      provenance: provenance, coalitionID: coalition, coalitionLeaderName: leader,
                      cpuPercent: cpu, threads: threads, memory: mem, gpuPercent: gpu, netRxBps: rx, netTxBps: tx,
                      diskReadBps: read, diskWriteBps: write, energyWatts: watts,
                      energyEstimated: provenance != .measured)
    }

    /// Groups like the engine: sums of present values, hidden = restricted members.
    static func group(_ ps: [ProcessSample], names: [AppKey: String] = [:], bundles: [AppKey: String] = [:]) -> [AppSample] {
        var order: [AppKey] = []
        var by: [AppKey: [ProcessSample]] = [:]
        for p in ps {
            if by[p.app] == nil { order.append(p.app) }
            by[p.app, default: []].append(p)
        }
        func sum(_ v: [Double?]) -> Double? { let x = v.compactMap { $0 }; return x.isEmpty ? nil : x.reduce(0, +) }
        return order.map { key in
            let m = by[key]!
            return AppSample(
                identity: AppIdentity(key: key, displayName: names[key] ?? m[0].name, bundlePath: bundles[key]),
                processIDs: m.map(\.id), hiddenProcessCount: m.filter { $0.provenance == .restricted }.count,
                isCurrentUser: m.contains(where: \.isCurrentUser),
                cpuPercent: sum(m.map(\.cpuPercent)), gpuPercent: sum(m.map(\.gpuPercent)),
                memory: m.compactMap(\.memory).isEmpty ? nil : m.compactMap(\.memory).reduce(0, +),
                netRxBps: sum(m.map(\.netRxBps)), netTxBps: sum(m.map(\.netTxBps)),
                diskReadBps: sum(m.map(\.diskReadBps)), diskWriteBps: sum(m.map(\.diskWriteBps)),
                energyWatts: sum(m.map(\.energyWatts)), energyEstimated: m.contains { $0.provenance != .measured },
                threads: m.compactMap(\.threads).reduce(0, +))
        }
    }

    static let xcode = AppKey(kind: .app, id: "com.apple.dt.Xcode")
    static let docker = AppKey(kind: .app, id: "com.docker.docker")
    static let safari = AppKey(kind: .app, id: "com.apple.Safari")
    static let ws = AppKey(kind: .process, id: "/System/Library/WindowServer")
    static let mds = AppKey(kind: .process, id: "/System/Library/mds_stores")
    static let suggestd = AppKey(kind: .process, id: "com.apple.suggestd")

    /// Xcode (1 proc), Docker Desktop (app + backend helper), Safari, WindowServer, mds_stores (root),
    /// suggestd coalition: 2 restricted members + a synthetic residual row.
    static func table() -> (processes: [ProcessSample], apps: [AppSample]) {
        let ps = [
            proc(1842, "Xcode", app: xcode, cpu: 212.4, gpu: 0.4, mem: 4_000_000_000, read: 4.1e6, watts: 7.1,
                 path: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            proc(2604, "com.docker.backend", app: docker, cpu: 11.3, mem: 1_500_000_000, rx: 3e5, read: 1.8e6,
                 watts: 0.6, path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"),
            proc(2600, "Docker Desktop", app: docker, cpu: 1.0, mem: 300_000_000, watts: 0.1,
                 path: "/Applications/Docker.app/Contents/MacOS/Docker Desktop"),
            proc(988, "Safari", app: safari, cpu: 18.7, gpu: 2.3, mem: 2_000_000_000, rx: 3.2e6, tx: 1e5, watts: 0.9,
                 path: "/Applications/Safari.app/Contents/MacOS/Safari"),
            proc(412, "WindowServer", app: ws, cpu: 14.2, gpu: 5.1, mem: 1_100_000_000, watts: 0.8,
                 user: "_windowserver", uid: 88, path: "/System/Library/WindowServer"),
            proc(377, "mds_stores", app: mds, cpu: 6.2, mem: 180_000_000, read: 96e6, watts: 0.3, user: "root", uid: 0),
            proc(3001, "suggestd", app: suggestd, user: "root", uid: 0, provenance: .restricted, coalition: 9100,
                 leader: "suggestd"),
            proc(3002, "suggestd", app: suggestd, user: "root", uid: 0, provenance: .restricted, coalition: 9100,
                 leader: "suggestd"),
            proc(-1, "suggestd", app: suggestd, cpu: 2.0, watts: 0.2, user: "root", uid: 0, provenance: .coalition,
                 coalition: 9100, leader: "suggestd", threads: nil),
        ]
        let apps = group(ps, names: [docker: "Docker Desktop"],
                         bundles: [xcode: "/Applications/Xcode.app", docker: "/Applications/Docker.app",
                                   safari: "/Applications/Safari.app"])
        return (ps, apps)
    }

    static func input(mode: NavigationModel.ProcessesMode = .apps, sort: ProcessColumn = .cpu,
                      descending: Bool = true, query: String = "", expanded: Set<AppKey> = [],
                      health: [SensorID: SensorStatus] = [:]) -> ProcessTableInput {
        let t = table()
        return ProcessTableInput(processes: t.processes, apps: t.apps, health: health, mode: mode, sort: sort,
                                 descending: descending, query: query, expanded: expanded, processCount: 612)
    }
}

@Suite("ProcessTableModel — pure build")
struct ProcessTableBuildTests {
    @Test func appsModeGroupsAndSortsByCPU() {
        let out = ProcessTableModel.build(PT.input())
        #expect(out.lines.map(\.name) == ["Xcode", "Safari", "WindowServer", "Docker Desktop", "mds_stores", "suggestd"])
        #expect(out.lines.allSatisfy { $0.depth == 0 })
        #expect(out.countLabel == "6 apps · 612 processes")
        let docker = out.lines[3]
        #expect(docker.cpu == 12.3)
        #expect(docker.kindLabel == "App · 2 processes")
        #expect(docker.pid == 2600)                                        // responsible (main) process
        #expect(docker.hasChildren)
        #expect(!out.lines[0].hasChildren)                                 // single-process app
        #expect(out.lines[2].kindLabel == "System")                        // WindowServer (_windowserver)
        #expect(out.lines[4].kindLabel == "Background")                    // mds_stores
    }

    @Test func parityAlternatesOnTopLevelOnly() {
        let out = ProcessTableModel.build(PT.input(expanded: [PT.docker]))
        let names = out.lines.map(\.name)
        #expect(names == ["Xcode", "Safari", "WindowServer", "Docker Desktop", "com.docker.backend",
                          "Docker Desktop", "mds_stores", "suggestd"])
        #expect(out.lines.map(\.parity) == [0, 1, 0, 1, 1, 1, 0, 1])
        #expect(out.lines[4].depth == 1 && out.lines[5].depth == 1)
        #expect(out.lines[3].isExpanded)
    }

    @Test func coalitionGroupExpandsToSyntheticRowAndRestrictedSummary() {
        let out = ProcessTableModel.build(PT.input(expanded: [PT.suggestd]))
        let tail = out.lines.suffix(3)
        #expect(tail.map(\.name) == ["suggestd", "suggestd", "+2 restricted"])
        let synthetic = tail[tail.startIndex + 1]
        #expect(synthetic.id == .process(.coalitionResidual(9100)))
        #expect(synthetic.kindLabel == "System")
        #expect(synthetic.cpuEstimated && synthetic.energyEstimated)
        #expect(tail.last?.rowKind == .restrictedSummary)
        #expect(tail.last?.id == .restricted(PT.suggestd))
    }

    @Test func processesModeListsEveryPid() {
        let out = ProcessTableModel.build(PT.input(mode: .processes))
        #expect(out.lines.count == 9)
        #expect(out.countLabel == "9 of 612 shown")
        #expect(out.lines.first?.name == "Xcode")
        let backend = out.lines.first { $0.name == "com.docker.backend" }
        #expect(backend?.kindLabel == "Background")
        #expect(out.lines.first { $0.pid == 2600 }?.kindLabel == "App")
        // Restricted rows: CPU "—" with the coalition tooltip, sorted last.
        let restricted = out.lines.filter { $0.provenance == .restricted }
        #expect(restricted.count == 2)
        #expect(out.lines.suffix(2).allSatisfy { $0.provenance == .restricted })
        #expect(restricted[0].reasons.cpu == "Owned by another user; counted in the suggestd coalition row")
    }

    @Test func sortsByEveryColumnWithNilsLast() {
        let byMem = ProcessTableModel.build(PT.input(sort: .memory))
        #expect(byMem.lines.first?.name == "Xcode")
        #expect(byMem.lines.last?.name == "suggestd")                       // nil memory last
        let byNet = ProcessTableModel.build(PT.input(sort: .network))
        #expect(byNet.lines.prefix(2).map(\.name) == ["Safari", "Docker Desktop"])  // rx+tx
        let byDisk = ProcessTableModel.build(PT.input(sort: .disk))
        #expect(byDisk.lines.first?.name == "mds_stores")
        let ascending = ProcessTableModel.build(PT.input(sort: .cpu, descending: false))
        #expect(ascending.lines.first?.name == "suggestd")                  // 2.0 (coalition residual)
        #expect(ascending.lines.last?.name == "Xcode")
        let energy = ProcessTableModel.build(PT.input(sort: .energy))
        #expect(energy.lines.first?.name == "Xcode")
    }

    @Test func searchMatchesNameBundleIdAndPidCaseInsensitive() {
        #expect(ProcessTableModel.build(PT.input(query: "SAF")).lines.map(\.name) == ["Safari"])
        #expect(ProcessTableModel.build(PT.input(query: "com.docker")).lines.map(\.name) == ["Docker Desktop"])
        // PID of a child matches its app in Apps mode.
        #expect(ProcessTableModel.build(PT.input(query: "2604")).lines.map(\.name) == ["Docker Desktop"])
        let procs = ProcessTableModel.build(PT.input(mode: .processes, query: "2604"))
        #expect(procs.lines.map(\.name) == ["com.docker.backend"])
        #expect(procs.countLabel == "1 of 612 shown")
        let none = ProcessTableModel.build(PT.input(query: "zzz"))
        #expect(none.lines.isEmpty)
        #expect(none.emptyMessage == "No processes match “zzz”")
        #expect(ProcessTableModel.build(PT.input(query: "  ")).lines.count == 6)
    }

    @Test func coalitionAndRestrictedMemoryTooltips() {
        let out = ProcessTableModel.build(PT.input(mode: .processes))
        let synthetic = out.lines.first { $0.id == .process(.coalitionResidual(9100)) }
        #expect(synthetic?.memory == nil)
        #expect(synthetic?.reasons.memory == "Requires root · updated when Processes is open")
        #expect(synthetic?.pid == nil)                                     // no leader pid known → "—"
        #expect(synthetic?.user == "root")
        // Idle rate on a measured row: "—" without a tooltip.
        let xcode = out.lines.first { $0.name == "Xcode" }
        #expect(xcode?.network == nil && xcode?.reasons.network == nil)
    }

    @Test func sensorUnavailableReasonsPropagate() {
        let health: [SensorID: SensorStatus] = [.gpuClients: .unavailable("Sensor not available on this Mac")]
        let out = ProcessTableModel.build(PT.input(mode: .processes, health: health))
        let mds = out.lines.first { $0.name == "mds_stores" }
        #expect(mds?.reasons.gpu == "Sensor not available on this Mac")
    }

    @Test func appRowPathTrimsToBundle() {
        let out = ProcessTableModel.build(PT.input())
        #expect(out.lines.first?.path == "/Applications/Xcode.app")
        let procs = ProcessTableModel.build(PT.input(mode: .processes))
        #expect(procs.lines.first?.path == "/Applications/Xcode.app/Contents/MacOS/Xcode")
    }
}

@Suite("ProcessTableModel — actions by owner")
struct ProcessTableActionTests {
    @Test func ownedRowsEnabledOthersDisabledWithOwner() {
        let out = ProcessTableModel.build(PT.input(mode: .processes))
        func row(_ n: String) -> ProcessRow { out.lines.first { $0.name == n }! }
        let xcode = ProcessTableModel.availability(for: row("Xcode"), serviceCanControl: true)
        #expect(xcode == ProcessActionAvailability(canQuit: true, canForceQuit: true, disabledHelp: nil))
        let mds = ProcessTableModel.availability(for: row("mds_stores"), serviceCanControl: true)
        #expect(mds == ProcessActionAvailability(canQuit: false, canForceQuit: false, disabledHelp: "Owned by root"))
        let ws = ProcessTableModel.availability(for: row("WindowServer"), serviceCanControl: true)
        #expect(ws.disabledHelp == "Owned by _windowserver")
        // The service can still veto an owned row.
        let vetoed = ProcessTableModel.availability(for: row("Xcode"), serviceCanControl: false)
        #expect(!vetoed.canQuit && !vetoed.canForceQuit)
    }

    @Test func appGroupsNeedEveryMemberOwned() {
        let out = ProcessTableModel.build(PT.input())
        func row(_ n: String) -> ProcessRow { out.lines.first { $0.name == n }! }
        #expect(ProcessTableModel.availability(for: row("Docker Desktop"), serviceCanControl: true).canQuit)
        let coalition = ProcessTableModel.availability(for: row("suggestd"), serviceCanControl: true)
        #expect(!coalition.canQuit && coalition.disabledHelp == "Owned by root")
    }

    @Test func targetsCarryRealPidsOnly() {
        let out = ProcessTableModel.build(PT.input())
        let docker = out.lines.first { $0.name == "Docker Desktop" }!
        guard case .app(let identity, let pids)? = docker.target else { Issue.record("no app target"); return }
        #expect(identity.key == PT.docker)
        #expect(Set(pids) == [2600, 2604])
        let coalition = out.lines.first { $0.name == "suggestd" }!
        guard case .app(_, let cpids)? = coalition.target else { Issue.record("no app target"); return }
        #expect(Set(cpids) == [3001, 3002])                                 // synthetic pid −1 excluded
        let procs = ProcessTableModel.build(PT.input(mode: .processes))
        let synthetic = procs.lines.first { $0.id == .process(.coalitionResidual(9100)) }!
        #expect(synthetic.target == nil)
        #expect(!ProcessTableModel.availability(for: synthetic, serviceCanControl: true).canQuit)
    }
}

@Suite("ProcessTableModel — observable")
@MainActor
struct ProcessTableObservableTests {
    func loaded(_ mode: NavigationModel.ProcessesMode = .apps) -> ProcessTableModel {
        let m = ProcessTableModel()
        let t = PT.table()
        m.update(processes: t.processes, apps: t.apps, health: [:], processCount: 612, mode: mode)
        return m
    }

    @Test func rebuildsOncePerFrameAndOnInputChange() {
        let m = loaded()
        #expect(m.buildCount == 1)
        let t = PT.table()
        m.update(processes: t.processes, apps: t.apps, health: [:], processCount: 612, mode: .apps)
        #expect(m.buildCount == 1)                                         // identical frame: no rebuild
        m.sort = .memory
        #expect(m.buildCount == 2)
        m.sort = .memory
        #expect(m.buildCount == 2)
        m.query = "saf"
        #expect(m.lines.map(\.name) == ["Safari"])
    }

    @Test func selectionSurvivesRefreshAndReorder() {
        let m = loaded()
        let selection = NavigationModel.ProcessSelection.app(PT.safari)
        var t = PT.table()
        t.processes = t.processes.map { p in
            var p = p
            if p.app == PT.safari { p.cpuPercent = 500 }
            return p
        }
        t.apps = PT.group(t.processes, names: [PT.docker: "Docker Desktop"])
        m.update(processes: t.processes, apps: t.apps, health: [:], processCount: 612, mode: .apps)
        #expect(m.lines.first?.name == "Safari")
        #expect(m.validated(selection) == selection)
        #expect(m.row(for: selection)?.cpu == 500)
        // A process that exits drops the selection.
        let gone = NavigationModel.ProcessSelection.process(ProcessID(pid: 99_999, startTimeUs: 1))
        #expect(m.validated(gone) == nil)
    }

    @Test func expansionTogglesAndArrowKeysCollapse() {
        let m = loaded()
        m.toggleExpanded(PT.docker)
        #expect(m.lines.count == 8)
        m.setExpanded(PT.docker, false)
        #expect(m.lines.count == 6)
        m.setExpanded(PT.xcode, true)                                     // no children: ignored
        #expect(m.expanded.isEmpty)
    }

    @Test func moveSelectionWalksVisibleLines() {
        let m = loaded()
        #expect(m.moved(nil, by: 1) == .app(PT.xcode))
        #expect(m.moved(.app(PT.xcode), by: 1) == .app(PT.safari))
        #expect(m.moved(.app(PT.xcode), by: -1) == .app(PT.xcode))
        m.toggleExpanded(PT.suggestd)
        // The "+N restricted" summary line is skipped.
        let last = m.moved(.app(PT.suggestd), by: 5)
        #expect(last == .process(.coalitionResidual(9100)))
    }

    @Test func modeToggleMapsSelection() {
        let m = loaded()
        let appSel = NavigationModel.ProcessSelection.app(PT.docker)
        #expect(m.selection(appSel, convertedTo: .processes) == .process(ProcessID(pid: 2600, startTimeUs: 1)))
        let procSel = NavigationModel.ProcessSelection.process(ProcessID(pid: 2604, startTimeUs: 1))
        #expect(m.selection(procSel, convertedTo: .apps) == .app(PT.docker))
        m.update(processes: PT.table().processes, apps: PT.table().apps, health: [:], processCount: 612,
                 mode: .processes)
        #expect(m.lines.count == 9)
        #expect(m.countLabel == "9 of 612 shown")
    }

    @Test func mockCalmScenarioBuilds() {
        let live = LiveModel.mock(.calm)
        let m = ProcessTableModel()
        m.update(from: live, mode: .apps)
        #expect(!m.lines.isEmpty)
        #expect(!m.lines.contains { $0.id == .app(.other) })
        let restricted = LiveModel.mock(.restricted)
        m.update(from: restricted, mode: .processes)
        #expect(m.lines.count > 300)
    }
}
