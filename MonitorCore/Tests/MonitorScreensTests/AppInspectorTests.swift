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
    init(result: ProcessSampleResult) { self.result = result }
    var calls: [Int32] { state.withLock { $0.calls } }
    var revealed: [URL] { state.withLock { $0.revealed } }
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
    let xcode = ProcessTarget.app(AppIdentity(key: PT.xcode, displayName: "Xcode"), pids: [1842])
    let rootProc = ProcessTarget.process(pid: 377, name: "mds_stores", path: nil, uid: 0)

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

    /// [Sample] goes through the injected sampler: success reveals the report, failure toasts; nothing is spawned.
    @Test func sampleSuccessRevealsFailureToasts() async {
        let ok = StubSampler(result: .done(URL(fileURLWithPath: "/tmp/Telltale-Xcode-1842.txt")))
        let c = ProcessActionCoordinator(actions: actions, sampler: ok)
        await c.sample(pid: 1842, name: "Xcode")
        #expect(ok.calls == [1842])
        #expect(ok.revealed == [URL(fileURLWithPath: "/tmp/Telltale-Xcode-1842.txt")])
        #expect(c.toast == nil && c.samplingPID == nil)
        let bad = StubSampler(result: .failed("sample exited with status 1"))
        c.sampler = bad
        await c.sample(pid: 1842, name: "Xcode")
        #expect(bad.revealed.isEmpty)
        #expect(c.toast?.text == "Couldn’t sample Xcode: sample exited with status 1")
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
        let path = LiveProcessSampler.reportURL(pid: 1842, name: "Final Cut/Pro",
                                                directory: URL(fileURLWithPath: "/tmp"))
        #expect(path.path == "/tmp/Telltale-Final-Cut-Pro-1842.txt")
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
