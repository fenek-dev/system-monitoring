import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import os
import Testing

/// Records `appSeries` calls; returns one point per metric.
actor RecordingAppSeriesProvider: HistoryProvider {
    private(set) var appSeriesCalls: [(AppKey, [AppMetric], HistoryRange, Date)] = []

    func series(_ metrics: [HistoryMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [HistoryMetric: [SeriesPoint]] { [:] }
    func appSeries(_ app: AppKey, _ metrics: [AppMetric], range: HistoryRange, end: Date, bucket: Duration?) async throws -> [AppMetric: [SeriesPoint]] {
        appSeriesCalls.append((app, metrics, range, end))
        var out: [AppMetric: [SeriesPoint]] = [:]
        for m in metrics { out[m] = [SeriesPoint(time: end, value: 1), SeriesPoint(time: end, value: 2)] }
        return out
    }
    func appShares(at time: Date, metric: AppMetric, range: HistoryRange, limit: Int) async throws -> [AppShare] { [] }
    func topApps(_ metric: AppMetric, in interval: DateInterval, limit: Int) async throws -> [AppAggregate] { [] }
    func total(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    func peak(_ metric: HistoryMetric, in interval: DateInterval) async throws -> Double? { nil }
    func events(in interval: DateInterval) async throws -> [HistoryEvent] { [] }
    func coverage() async throws -> DateInterval? { nil }
    func exportCSV(range: HistoryRange, end: Date, to url: URL) async throws -> ExportSummary {
        ExportSummary(rows: 0, bytes: 0, url: url)
    }
}

/// Records sample/reveal calls; never spawns `sample`.
final class StubSampler: ProcessSampling {
    private let state = OSAllocatedUnfairLock(initialState: (calls: [Int32](), revealed: [URL]()))
    let result: ProcessSampleResult
    /// What the kernel reports for the pid now (nil = gone).
    let startTime: UInt64?
    init(result: ProcessSampleResult, startTime: UInt64? = 1) {
        self.result = result
        self.startTime = startTime
    }
    var calls: [Int32] { state.withLock { $0.calls } }
    var revealed: [URL] { state.withLock { $0.revealed } }
    func startTimeUs(pid: Int32) -> UInt64? { startTime }
    func sample(pid: Int32, name: String) async -> ProcessSampleResult {
        state.withLock { $0.calls.append(pid) }
        return result
    }
    func reveal(_ url: URL) { state.withLock { $0.revealed.append(url) } }
}

@Suite("AppInspector — actions")
@MainActor
struct AppInspectorActionTests {
    let log = ActionLog()
    var actions: ProcessActions { MockDataProvider(scenario: .calm).processActions(log: log) }
    let xcode = ProcessTarget.app(AppIdentity(key: PT.xcode, displayName: "Xcode"),
                                  processes: [ProcessID(pid: 1842, startTimeUs: 1)])
    let rootProc = ProcessTarget.process(ProcessID(pid: 377, startTimeUs: 1), name: "mds_stores", path: nil, uid: 0)

    @Test func quitGoesThroughServiceAndToasts() async {
        let c = ProcessActionCoordinator(actions: actions)
        await c.quit(xcode)
        #expect(log.entries == ["quit Xcode -> done"])
        #expect(c.toast?.text == "Xcode quit.")
    }

    @Test func forceQuitNeedsConfirmation() async {
        struct Box: Sendable { var asked: [[String]] = []; var answer = false }
        let box = OSAllocatedUnfairLock(initialState: Box())
        let c = ProcessActionCoordinator(actions: actions, confirm: { title, message, button in
            box.withLock { $0.asked.append([title, message, button]); return $0.answer }
        })
        await c.forceQuit(xcode)                                           // cancelled in the dialog
        let asked = box.withLock { $0.asked }
        #expect(asked == [["Force quit “Xcode”?", ProcessActionCoordinator.dialogMessage, "Force Quit"]])
        #expect(log.entries.isEmpty)                                       // nothing sent without confirming
        #expect(c.toast == nil)
        box.withLock { $0.answer = true }
        await c.forceQuit(xcode)
        #expect(log.entries == ["forceQuit Xcode -> done"])
        #expect(c.toast?.text == "Xcode was force quit.")
    }

    /// Quit / Force Quit results from the service use the shared copy: an unconfirmed quit is only "asked", a
    /// target whose pid was reused or exited says so, and failures name the force quit.
    @Test func coordinatorToastCopy() {
        let c = ProcessActionCoordinator()
        c.report(xcode, .requested, force: false)
        #expect(c.toast?.text == "Asked Xcode to quit.")
        c.report(xcode, .exited, force: true)
        #expect(c.toast?.text == "Process has exited")
        c.report(xcode, .failed("EPERM"), force: true)
        #expect(c.toast?.text == "Couldn't force quit Xcode: EPERM")
    }

    /// [Sample] goes through the injected sampler: success reveals the report, failure toasts; nothing is spawned.
    @Test func sampleSuccessRevealsFailureToasts() async {
        let ok = StubSampler(result: .done(URL(fileURLWithPath: "/tmp/Telltale-Xcode-1842.txt")))
        let c = ProcessActionCoordinator(actions: actions, sampler: ok)
        let xcodeID = ProcessID(pid: 1842, startTimeUs: 1)
        await c.sample(xcodeID, name: "Xcode")
        #expect(ok.calls == [1842])
        #expect(ok.revealed == [URL(fileURLWithPath: "/tmp/Telltale-Xcode-1842.txt")])
        #expect(c.toast == nil && c.samplingPID == nil)
        let bad = StubSampler(result: .failed("sample timed out after 15 s"))
        c.sampler = bad
        await c.sample(xcodeID, name: "Xcode")
        #expect(bad.revealed.isEmpty)
        #expect(c.samplingPID == nil)                                     // cleared after a timeout too
        #expect(c.toast?.text == "Couldn’t sample Xcode: sample timed out after 15 s")
    }

    /// PID reuse: the start time is re-checked right before spawning; a mismatch (or a vanished pid) never samples.
    @Test func sampleRefusesAReusedOrExitedPid() async {
        let reused = StubSampler(result: .done(URL(fileURLWithPath: "/tmp/x.txt")), startTime: 999)
        let c = ProcessActionCoordinator(actions: actions, sampler: reused)
        await c.sample(ProcessID(pid: 1842, startTimeUs: 1), name: "Xcode")
        #expect(reused.calls.isEmpty)
        #expect(c.toast?.text == "Process has exited")
        let gone = StubSampler(result: .done(URL(fileURLWithPath: "/tmp/x.txt")), startTime: nil)
        c.sampler = gone
        await c.sample(ProcessID(pid: 1842, startTimeUs: 1), name: "Xcode")
        #expect(gone.calls.isEmpty)
    }

    /// The live runner's timeout path, with a stub executable (`/bin/sleep`) instead of `sample`.
    @Test func liveSamplerTimesOutAndKills() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-samples-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let slow = LiveProcessSampler(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: 0.3,
                                      arguments: { _, _ in ["30"] }, reportsRoot: root)
        let started = Date()
        let result = await slow.sample(pid: 1, name: "slow")
        #expect(result == .failed("sample timed out after 0.3 s"))
        #expect(Date().timeIntervalSince(started) < 5)
        // M5: a failed run leaves no report directory behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let failing = LiveProcessSampler(executable: URL(fileURLWithPath: "/usr/bin/false"), reportsRoot: root)
        #expect(await failing.sample(pid: 1, name: "x") == .failed("sample exited with status 1"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    /// Report directories older than a day are pruned (launch / next sample); newer ones are kept for the reveal.
    @Test func samplerPrunesOldReportDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tt-samples-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let old = try LiveProcessSampler.makeRunDirectory(in: root)
        let fresh = try LiveProcessSampler.makeRunDirectory(in: root)
        var st = stat()
        #expect(lstat(fresh.path, &st) == 0 && st.st_mode & 0o777 == 0o700)
        #expect(lstat(root.path, &st) == 0 && st.st_mode & 0o777 == 0o700)
        try "r".write(to: old.appendingPathComponent("Telltale-x.txt"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        LiveProcessSampler.pruneReports(in: root)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
        // A symlinked root is refused (never follow a planted link).
        let link = fm.temporaryDirectory.appendingPathComponent("tt-samples-link-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? fm.removeItem(at: link) }
        #expect(throws: (any Error).self) { try LiveProcessSampler.makeRunDirectory(in: link) }
    }

    /// A leftover or planted file is never trusted: symlinks fail, stale files fail, fresh regular files pass.
    @Test func reportFileChecks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tt-sample-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("r.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        #expect(LiveProcessSampler.isFreshRegularFile(file.path, notBefore: Date().addingTimeInterval(-10)))
        #expect(!LiveProcessSampler.isFreshRegularFile(file.path, notBefore: Date().addingTimeInterval(60)))
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(!LiveProcessSampler.isFreshRegularFile(link.path, notBefore: .distantPast))
        #expect(!LiveProcessSampler.isFreshRegularFile(dir.appendingPathComponent("none").path, notBefore: .distantPast))
        let name = LiveProcessSampler.reportName(pid: 1842, name: "Final Cut/Pro", token: "ABCDEF12-3456")
        #expect(name == "Telltale-Final-Cut-Pro-1842-ABCDEF12.txt")
    }

    @Test func sampleEnablementByOwnerSelfAndSynthetic() {
        let procs = ProcessTableModel.build(PT.input(mode: .processes))
        func availability(_ name: String) -> ProcessActionAvailability {
            ProcessTableModel.availability(for: procs.lines.first { $0.name == name }!, serviceCanControl: true,
                                           ownPID: 9, ownBundleID: "dev.telltale.Telltale")
        }
        #expect(availability("Xcode").canSample)                           // own user, real pid
        #expect(!availability("mds_stores").canSample)                     // root
        let synthetic = procs.lines.first { $0.id == .process(.coalitionResidual(9100)) }!
        #expect(!ProcessTableModel.availability(for: synthetic, serviceCanControl: true).canSample)
        let xcode = procs.lines.first { $0.name == "Xcode" }!
        let selfRow = ProcessTableModel.availability(for: xcode, serviceCanControl: true, ownPID: 1842,
                                                     ownBundleID: nil)
        #expect(!selfRow.canSample)                                        // never Telltale itself
        #expect(procs.lines.first { $0.name == "Xcode" }?.sampleID == ProcessID(pid: 1842, startTimeUs: 1))
        let apps = ProcessTableModel.build(PT.input())
        #expect(apps.lines.first { $0.name == "Docker Desktop" }?.sampleID?.pid == 2600)   // responsible process
        #expect(apps.lines.first { $0.name == "suggestd" }?.sampleID == nil)              // coalition group
    }

    @Test func forceQuitWithoutDialogHostDoesNothing() async {
        let c = ProcessActionCoordinator(actions: actions, confirm: nil)
        await c.forceQuit(xcode)
        #expect(log.entries.isEmpty)
    }

    @Test func refusedActionToastsAndCancelledIsSilent() async {
        let c = ProcessActionCoordinator(actions: actions)
        await c.quit(rootProc)
        #expect(c.toast?.text == "Not permitted to quit mds_stores.")
        let before = c.toast
        c.report(xcode, .cancelled, force: false)
        #expect(c.toast == before)
    }

    @Test func toastDismissOnlyClearsItsOwnId() async {
        let c = ProcessActionCoordinator(actions: actions)
        await c.quit(xcode)
        let first = c.toast!.id
        await c.quit(xcode)
        c.dismissToast(first)
        #expect(c.toast != nil)
        c.dismissToast(c.toast!.id)
        #expect(c.toast == nil)
    }

    @Test func availabilityCombinesOwnerAndService() {
        let out = ProcessTableModel.build(PT.input())
        let xcodeRow = out.lines.first { $0.name == "Xcode" }!
        let a = ProcessTableModel.availability(for: xcodeRow, serviceCanControl: actions.canControl(xcodeRow.target!))
        #expect(a.canQuit && a.canForceQuit)
        let noop = ProcessTableModel.availability(for: xcodeRow,
                                                  serviceCanControl: ProcessActions.noop.canControl(xcodeRow.target!))
        #expect(!noop.canQuit)
    }
}

@Suite("AppInspector — detail")
@MainActor
struct AppInspectorDetailTests {
    @Test func metaLines() {
        let apps = ProcessTableModel.build(PT.input())
        let docker = apps.lines.first { $0.name == "Docker Desktop" }!
        #expect(AppInspector.meta(docker) == "PID 2600 · arthur · 2 processes")
        let procs = ProcessTableModel.build(PT.input(mode: .processes))
        let xcode = procs.lines.first { $0.name == "Xcode" }!
        #expect(AppInspector.meta(xcode) == "PID 1842 · arthur · 4 threads")
        let synthetic = procs.lines.first { $0.id == .process(.coalitionResidual(9100)) }!
        #expect(AppInspector.meta(synthetic) == "PID — · root")
    }

    @Test func livePointsSumDirectionsForApps() {
        let live = LiveModel.mock(.calm)
        let m = ProcessTableModel()
        m.update(from: live, mode: .apps)
        let row = m.lines.first { $0.rowKind == .app && $0.network != nil }!
        let model = AppInspectorModel()
        let rx = live.appSeries(row.appKey, .netRx), tx = live.appSeries(row.appKey, .netTx)
        let net = model.points(.network, row: row, live: live)
        #expect(net.count == min(rx.count, tx.count))
        #expect(net.last?.value == (rx.last?.value ?? 0) + (tx.last?.value ?? 0))
        #expect(model.points(.cpu, row: row, live: live) == live.appSeries(row.appKey, .cpu))
    }

    @Test func storedRangeQueriesHistoryForTheApp() async {
        let provider = RecordingAppSeriesProvider()
        let model = AppInspectorModel()
        let end = MockDataProvider.referenceDate
        model.range = .day
        await model.load(app: PT.docker, range: .day, end: end, provider: provider)
        let calls = await provider.appSeriesCalls
        #expect(calls.count == 1)
        #expect(calls.first?.0 == PT.docker && calls.first?.2 == .day)
        let row = ProcessTableModel.build(PT.input()).lines.first { $0.name == "Docker Desktop" }!
        #expect(model.points(.network, row: row, live: LiveModel()).map(\.value) == [2, 4])   // rx + tx
        // Same key: cached, no second query. Live: never queries.
        await model.load(app: PT.docker, range: .day, end: end, provider: provider)
        await model.load(app: PT.docker, range: .live, end: end, provider: provider)
        #expect(await provider.appSeriesCalls.count == 1)
        // Another app's stored series are not shown for this row.
        let xcode = ProcessTableModel.build(PT.input()).lines.first { $0.name == "Xcode" }!
        #expect(model.points(.cpu, row: xcode, live: LiveModel()).isEmpty)
    }

    @Test func processRingRecordsOncePerFrameAndCaps() {
        let procs = ProcessTableModel.build(PT.input(mode: .processes))
        let xcode = procs.lines.first { $0.name == "Xcode" }!
        let model = AppInspectorModel()
        let t0 = MockDataProvider.referenceDate
        model.record(xcode, at: t0)
        model.record(xcode, at: t0)                                        // same frame: ignored
        #expect(model.livePoints(.cpu, row: xcode, live: LiveModel()).count == 1)
        for i in 1...80 { model.record(xcode, at: t0.addingTimeInterval(Double(i))) }
        #expect(model.livePoints(.cpu, row: xcode, live: LiveModel()).count == AppInspectorModel.ringCapacity)
        let safari = procs.lines.first { $0.name == "Safari" }!
        model.record(safari, at: t0.addingTimeInterval(100))                // selection changed: new ring
        #expect(model.livePoints(.cpu, row: safari, live: LiveModel()).count == 1)
        #expect(model.livePoints(.cpu, row: xcode, live: LiveModel()).isEmpty)
    }

    @Test func connectionsFilteredToAppOrProcess() {
        let conns = [
            ConnectionSample(id: 1, process: ProcessID(pid: 2604, startTimeUs: 1), app: PT.docker, proto: .tcp,
                             remoteAddress: "10.0.0.1", remotePort: 443, rxBps: 10, txBps: 0),
            ConnectionSample(id: 2, process: ProcessID(pid: 2600, startTimeUs: 1), app: PT.docker, proto: .udp,
                             remotePort: 53, remoteHost: "example.com", rxBps: 500, txBps: 5),
            ConnectionSample(id: 3, process: ProcessID(pid: 988, startTimeUs: 1), app: PT.safari, proto: .tcp),
        ]
        let apps = ProcessTableModel.build(PT.input())
        let docker = apps.lines.first { $0.name == "Docker Desktop" }!
        #expect(AppInspectorModel.connections(conns, for: docker).map(\.id) == [2, 1])     // busiest first
        let procs = ProcessTableModel.build(PT.input(mode: .processes))
        let backend = procs.lines.first { $0.name == "com.docker.backend" }!
        #expect(AppInspectorModel.connections(conns, for: backend).map(\.id) == [1])
        let synthetic = procs.lines.first { $0.id == .process(.coalitionResidual(9100)) }!
        #expect(AppInspectorModel.connections(conns, for: synthetic).isEmpty)
    }

    @Test func laneDomains() {
        func pts(_ v: Double) -> [SeriesPoint] { [SeriesPoint(time: .now, value: v)] }
        #expect(InspectorLane.cpu.domain(pts(40)) == 0...100)
        #expect(InspectorLane.cpu.domain(pts(250)).upperBound >= 250)
        #expect(InspectorLane.gpu.domain(pts(250)) == 0...100)
        #expect(InspectorLane.energy.domain(pts(0.2)) == 0...1)
        #expect(InspectorLane.network.domain(pts(3e6)).upperBound >= 3e6)
    }
}
