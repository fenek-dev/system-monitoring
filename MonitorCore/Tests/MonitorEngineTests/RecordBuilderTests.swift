import Foundation
import MonitorModel
import Testing
@testable import MonitorEngine

@Suite struct RecordBuilderTests {
    private func app(_ id: String, cpu: Double? = nil, gpu: Double? = nil, mem: UInt64? = nil, rx: Double? = nil,
                     tx: Double? = nil, dr: Double? = nil, dw: Double? = nil, watts: Double? = nil,
                     kind: AppKey.Kind = .app) -> AppSample {
        AppSample(identity: AppIdentity(key: AppKey(kind: kind, id: id), displayName: id), cpuPercent: cpu, gpuPercent: gpu,
                  memory: mem, netRxBps: rx, netTxBps: tx, diskReadBps: dr, diskWriteBps: dw, energyWatts: watts)
    }

    private func frame(_ apps: [AppSample]) -> SystemFrame {
        var m = SystemMetrics()
        m[.cpuUsage] = 0.3
        return SystemFrame(wallTime: Date(timeIntervalSince1970: 100), interval: .seconds(5), apps: apps, metrics: m)
    }

    @Test func systemMetricsTimeAndInterval() {
        let r = RecordBuilder().record(from: frame([]))
        #expect(r.time == Date(timeIntervalSince1970: 100))
        #expect(r.interval == .seconds(5))
        #expect(r.system[.cpuUsage] == 0.3)
        #expect(r.apps.isEmpty)
    }

    @Test func intervalIsNominalNotMeasured() {
        var f = frame([])
        f.mode = .interactive
        f.interval = .milliseconds(1_200)
        #expect(RecordBuilder().record(from: f).interval == .seconds(1))
    }

    @Test func zeroGPUFoldsIntoOther() {
        let r = RecordBuilder().record(from: frame([app("idle", gpu: 0)]))
        #expect(r.apps.map(\.identity.key) == [.other])
        #expect(r.apps.first?.metrics[.gpu] == 0)
    }

    @Test func noOtherRowWhenFoldedAppsHaveNoValues() {
        let r = RecordBuilder().record(from: frame([app("empty"), app("big", cpu: 50)]))
        #expect(r.apps.map(\.identity.displayName) == ["big"])
    }

    @Test func missingIntervalFallsBackToModeInterval() {
        var f = frame([])
        f.interval = nil
        f.mode = .background
        #expect(RecordBuilder().record(from: f).interval == .seconds(5))
    }

    @Test(arguments: [
        ("cpu", true), ("cpuLow", false), ("gpu", true), ("net", true), ("netLow", false), ("disk", true),
        ("diskLow", false), ("mem", true), ("memLow", false),
    ])
    func thresholds(_ name: String, _ kept: Bool) {
        let apps: [String: AppSample] = [
            "cpu": app("cpu", cpu: 0.5), "cpuLow": app("cpuLow", cpu: 0.49),
            "gpu": app("gpu", gpu: 0.01),
            "net": app("net", rx: 1_000, tx: 24), "netLow": app("netLow", rx: 1_000, tx: 23),
            "disk": app("disk", dr: 100_000, dw: 2_400), "diskLow": app("diskLow", dr: 100_000, dw: 2_399),
            "mem": app("mem", mem: 200 << 20), "memLow": app("memLow", mem: (200 << 20) - 1),
        ]
        let r = RecordBuilder().record(from: frame([apps[name]!]))
        #expect(r.apps.contains { $0.identity.displayName == name } == kept)
        #expect(r.apps.contains { $0.identity.key == .other } == !kept)
    }

    @Test func smallAppsFoldIntoOther() throws {
        let r = RecordBuilder().record(from: frame([
            app("big", cpu: 50, mem: 1 << 30, watts: 2),
            app("s1", cpu: 0.1, mem: 1_000, watts: 0.01), app("s2", cpu: 0.2, rx: 10),
            app("already-other", cpu: 0.3, kind: .other),
        ]))
        #expect(r.apps.map(\.identity.key.kind) == [.app, .other])
        let big = try #require(r.apps.first)
        #expect(big.metrics[.cpu] == 50 && big.metrics[.memory] == Double(1 << 30) && big.metrics[.energy] == 2)
        let other = try #require(r.apps.last)
        #expect(abs(other.metrics[.cpu]! - 0.6) < 1e-12)
        #expect(other.metrics[.memory] == 1_000)
        #expect(other.metrics[.netRx] == 10)
        #expect(other.metrics[.netTx] == nil)                 // nobody had it
        #expect(other.metrics[.energy] == 0.01)
        #expect(other.identity.displayName == "Other")
    }

    @Test func customConfig() {
        var c = RecordConfig()
        c.minCPUPercent = 10
        #expect(RecordBuilder(config: c).record(from: frame([app("a", cpu: 5)])).apps.map(\.identity.key) == [.other])
    }
}
