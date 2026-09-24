import Foundation
import Observation
import os
import Testing
import MonitorModel
@testable import MonitorLive

/// Counts onChange callbacks of one `withObservationTracking` registration.
final class FireCount: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { lock.withLock { $0 } }
    func bump() { lock.withLock { $0 += 1 } }
}

@MainActor
func observe(_ read: @escaping @MainActor () -> Void) -> FireCount {
    let c = FireCount()
    withObservationTracking { read() } onChange: { c.bump() }
    return c
}

@MainActor
func frame(t: Double, cpuUsage: Double = 0.4, memUsed: UInt64 = 1_000, apps: [AppSample] = [],
           interval: Duration? = .seconds(1), alert: AlertState = .calm) -> SystemFrame {
    var m = SystemMetrics()
    m[.cpuUsage] = cpuUsage
    m[.memUsed] = Double(memUsed)
    return SystemFrame(
        wallTime: Date(timeIntervalSince1970: t), uptimeNs: UInt64(t * 1e9), interval: interval, mode: .interactive,
        cpu: CPUSnapshot(usage: cpuUsage), memory: MemorySnapshot(total: 16_000, used: memUsed),
        apps: apps, alert: alert, metrics: m)
}

@MainActor
@Suite struct LiveModelTests {
    @Test func memoryOnlyChangeDoesNotFireCPUObserver() {
        let model = LiveModel()
        model.isPresenting = true
        model.apply(frame(t: 0))
        let cpu = observe { _ = model.cpu; _ = model.cpuVersion; _ = model.version(.cpu) }
        let mem = observe { _ = model.memory }
        let memVersion = model.memoryVersion
        model.apply(frame(t: 1, memUsed: 2_000))
        #expect(cpu.value == 0)
        #expect(mem.value == 1)
        #expect(model.memoryVersion == memVersion + 1)
        #expect(model.memory.used == 2_000)
    }

    @Test func equalFrameFiresNothing() {
        let model = LiveModel()
        model.isPresenting = true
        let f = frame(t: 0, apps: [app("a", cpu: 10)])
        model.apply(f)
        let all = observe {
            _ = model.alert; _ = model.phase; _ = model.samplingInterval; _ = model.device
            _ = model.cpu; _ = model.gpu; _ = model.memory; _ = model.network; _ = model.thermals
            _ = model.power; _ = model.disk; _ = model.processes; _ = model.apps; _ = model.connections
            _ = model.sensorHealth; _ = model.lastUpdate
            for c in MonitorModel.Category.allCases { _ = model.version(c) }
            _ = model.appsVersion
        }
        model.apply(f)
        #expect(all.value == 0)
    }

    @Test func notPresentingUpdatesOnlyAlertPhaseAndHistory() {
        let model = LiveModel()
        var alert = AlertState.calm
        alert.level = .elevated
        let snapshots = observe { _ = model.cpu; _ = model.apps; _ = model.version(.cpu) }
        model.apply(frame(t: 0, cpuUsage: 0.9, apps: [app("a", cpu: 10)], alert: alert))
        #expect(snapshots.value == 0)
        #expect(model.cpu == CPUSnapshot())
        #expect(model.alert.level == .elevated)
        #expect(model.phase == .live)
        #expect(model.series(.cpuUsage).map(\.value) == [0.9])
        #expect(model.lastUpdate == nil)
    }

    @Test func startPresentingAppliesLatestFrame() {
        let model = LiveModel()
        model.apply(frame(t: 0, cpuUsage: 0.9, apps: [app("a", cpu: 10)]))
        let v = model.cpuVersion
        model.isPresenting = true
        #expect(model.cpu.usage == 0.9)
        #expect(model.apps.count == 1)
        #expect(model.cpuVersion > v)
        #expect(model.lastUpdate == Date(timeIntervalSince1970: 0))
    }

    @Test func phaseCollectingUntilFrameWithRates() {
        let model = LiveModel()
        guard case .collecting = model.phase else { Issue.record("initial phase \(model.phase)"); return }
        model.apply(frame(t: 0, interval: nil))
        guard case .collecting = model.phase else { Issue.record("no-rate frame → \(model.phase)"); return }
        model.apply(frame(t: 1))
        #expect(model.phase == .live)
    }

    @Test func pauseSetsPhaseDimsGlyphAndInsertsGap() {
        let model = LiveModel()
        model.apply(frame(t: 0))
        let at = Date(timeIntervalSince1970: 1)
        model.setPaused(true, at: at)
        #expect(model.phase == .paused(since: at))
        #expect(model.alert.paused)
        #expect(model.alert.level == .calm)
        #expect(model.samplingInterval == nil)
        model.setPaused(false, at: Date(timeIntervalSince1970: 50))
        #expect(model.phase == .collecting(since: Date(timeIntervalSince1970: 50)))
        #expect(!model.alert.paused)
        model.apply(frame(t: 51))
        #expect(model.series(.cpuUsage, window: .seconds(120)).map { $0.value == nil } == [false, true, false])
    }

    @Test func samplingIntervalFollowsMode() {
        let model = LiveModel()
        var f = frame(t: 0)
        f.mode = .background
        model.apply(f)
        #expect(model.samplingInterval == .seconds(5))
    }

    @Test func topAppsPerCategory() {
        let model = LiveModel()
        model.isPresenting = true
        var net = app("net", cpu: 1)
        net.netRxBps = 900
        net.netTxBps = 200
        var disk = app("disk", cpu: 2)
        disk.diskWriteBps = 5_000
        model.apply(frame(t: 0, apps: [app("a", cpu: 50), app("b", cpu: 70), net, disk,
                                       app("other", cpu: 999, kind: .other)]))
        #expect(model.topApps(.cpu, count: 2).map(\.identity.displayName) == ["b", "a"])
        #expect(model.topApps(.network, count: 1).map(\.identity.displayName) == ["net"])
        #expect(model.topApps(.disk, count: 1).map(\.identity.displayName) == ["disk"])
        #expect(model.topApps(.memory).isEmpty)                  // no memory values in this frame
    }

    @Test func topAppsByMemoryUsesByteValues() {
        let model = LiveModel()
        model.isPresenting = true
        var small = app("small", cpu: 1), big = app("big", cpu: 1)
        small.memory = 1_000
        big.memory = 3 << 30
        model.apply(frame(t: 0, apps: [small, big]))
        #expect(model.topApps(.memory).map(\.identity.displayName) == ["big", "small"])
        #expect(!model.topApps(.cpu, count: 10).contains { $0.identity.key == .other })
        #expect(model.topApps(.gpu).isEmpty)          // nobody has a GPU value
    }

    @Test func topConsumerPrefersEnergyAndExcludesSystem() {
        let model = LiveModel()
        model.isPresenting = true
        model.apply(frame(t: 0, apps: [app("sys", cpu: 300, kind: .system, watts: 9), app("a", cpu: 90, watts: 1),
                                       app("b", cpu: 10, watts: 2)]))
        #expect(model.topConsumer?.identity.displayName == "b")
        model.apply(frame(t: 1, apps: [app("sys", cpu: 300, kind: .system), app("a", cpu: 90), app("b", cpu: 10)]))
        #expect(model.topConsumer?.identity.displayName == "a")
    }

    @Test func topAppsTrackedThroughAppsVersion() {
        let model = LiveModel()
        model.isPresenting = true
        model.apply(frame(t: 0, apps: [app("a", cpu: 1)]))
        let obs = observe { _ = model.topApps(.cpu) }
        model.apply(frame(t: 1, apps: [app("a", cpu: 2)]))
        #expect(obs.value == 1)
        #expect(model.topApps(.cpu).first?.cpuPercent == 2)
    }

    @Test func lookupsByKey() {
        let model = LiveModel()
        model.isPresenting = true
        let key = AppKey(kind: .app, id: "a")
        var f = frame(t: 0, apps: [app("a", cpu: 1)])
        f.processes = [ProcessSample(id: ProcessID(pid: 10, startTimeUs: 1), app: key),
                       ProcessSample(id: ProcessID(pid: 11, startTimeUs: 1), app: .system)]
        f.sensorHealth = [.smc: .unavailable("no SMC")]
        model.apply(f)
        #expect(model.app(key)?.cpuPercent == 1)
        #expect(model.app(.other) == nil)
        #expect(model.processes(of: key).map(\.pid) == [10])
        #expect(model.status(of: .smc) == .unavailable("no SMC"))
        #expect(model.status(of: .hostCPU) == .ok)
    }

    @Test func appSeriesAvailableWhileHidden() {
        let model = LiveModel()
        model.apply(frame(t: 0, apps: [app("a", cpu: 5)]))
        model.apply(frame(t: 1, apps: [app("a", cpu: 6)]))
        #expect(model.appSeries(AppKey(kind: .app, id: "a"), .cpu).map(\.value) == [5, 6])
    }

    @Test func seriesTrackedThroughCategoryVersion() {
        let model = LiveModel()
        model.isPresenting = true
        model.apply(frame(t: 0))
        let obs = observe { _ = model.series(.cpuUsage) }
        model.apply(frame(t: 1, cpuUsage: 0.8))
        #expect(obs.value == 1)
    }

    @Test func idleCategoryChartStillScrolls() {
        let model = LiveModel()
        model.isPresenting = true
        model.apply(frame(t: 0))
        let chart = observe { _ = model.series(.cpuUsage) }
        let snapshot = observe { _ = model.cpu; _ = model.version(.cpu) }
        model.apply(frame(t: 1))                                        // same CPU snapshot, new time
        #expect(chart.value == 1)
        #expect(snapshot.value == 0)
        #expect(model.series(.cpuUsage).count == 2)
    }

    @Test func appSeriesObserverFiresOnNewPoint() {
        let model = LiveModel()
        model.isPresenting = true
        let apps = [app("a", cpu: 1)]
        model.apply(frame(t: 0, apps: apps))
        let chart = observe { _ = model.appSeries(AppKey(kind: .app, id: "a"), .cpu) }
        model.apply(frame(t: 1, apps: apps))
        #expect(chart.value == 1)
    }

    private func app(_ id: String, cpu: Double?, kind: AppKey.Kind = .app, watts: Double? = nil) -> AppSample {
        liveApp(id, cpu: cpu, kind: kind, watts: watts)
    }
}
