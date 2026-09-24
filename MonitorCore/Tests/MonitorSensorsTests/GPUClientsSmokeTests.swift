import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// `TELLTALE_HW_TESTS=1 scripts/test.sh GPUClientsSmokeTests`.
@Suite(.enabled(if: W6bFixture.hardwareTests), .serialized, .w6bExclusive)
struct GPUClientsSmokeTests {
    private func ownGPUTime(_ r: GPUClientsReading) -> UInt64 {
        r.clients.filter { $0.pid == getpid() }.reduce(0) { $0 + $1.gpuTimeNs }
    }

    @Test func ownMetalLoadShowsHighShare() throws {
        let sensor = GPUClientsSensor()
        try sensor.prepare()
        defer { sensor.invalidate() }
        let idle = try sensor.sample(SampleContext())
        let load = try #require(W6bGPULoad.start())
        defer { load.stop() }
        W6bFixture.sleep(1)
        let a = try sensor.sample(SampleContext())
        W6bFixture.sleep(2)
        let b = try sensor.sample(SampleContext())
        if W6bFixture.capture {
            // "Device Utilization %" is computed since the previous read by ANY reader: back-to-back reads give 0.
            W6bFixture.sleep(1)
            let data = try PropertyListSerialization.data(fromPropertyList: sensor.rawDump(), format: .xml, options: 0)
            try data.write(to: W6bFixture.sourceURL("gpu_clients.plist"))
        }
        load.stop()
        let dt = Double(b.capturedNs - a.capturedNs) / 1e9
        let t0 = ownGPUTime(a.reading), t1 = ownGPUTime(b.reading)
        let pct = t1 >= t0 ? Double(t1 - t0) / 1e9 / dt * 100 : -1
        // Σ of all clients' deltas (same clientID in both samples) vs Device Utilization %.
        let before = Dictionary(a.reading.clients.map { ($0.clientID, $0.gpuTimeNs) }, uniquingKeysWith: +)
        let sum = b.reading.clients.reduce(0.0) { acc, c in
            guard let old = before[c.clientID], c.gpuTimeNs >= old else { return acc }
            return acc + Double(c.gpuTimeNs - old) / 1e9 / dt * 100
        }
        let mine = b.reading.clients.filter { $0.pid == getpid() }
        print("W6b gpu: clients=\(b.reading.clients.count) own=\(mine.map { "\($0.creatorName)#\($0.clientID)" }) "
              + String(format: "own=%.1f%% Σ=%.1f%% util idle=%.0f load=%.0f mem=%lluMB", pct, sum,
                       idle.reading.deviceUtilization ?? -1, b.reading.deviceUtilization ?? -1,
                       (b.reading.inUseSystemMemory ?? 0) >> 20))
        #expect(!mine.isEmpty)
        #expect(pct >= 30, "own pid GPU share \(pct) %")
        // Saturating compute load: the clients' time deltas must cover (nearly) the whole GPU.
        // deviceUtilization is informational only (resets on every read by any process; printed above).
        #expect(sum >= 80, "Σ client share \(sum) %")
        #expect(sum <= 110, "Σ client share \(sum) % (double counting?)")
        #expect((b.reading.inUseSystemMemory ?? 0) > 0)
        #expect(b.reading.clients.allSatisfy { $0.pid > 0 || $0.creatorName == "kernel_task" })
    }

    @Test func bench() throws {
        let sensor = GPUClientsSensor()
        try sensor.prepare()
        defer { sensor.invalidate() }
        var ns: [UInt64] = []
        var n = 0
        for _ in 0..<30 {
            let t = w6bUptimeNs()
            n = try sensor.sample(SampleContext()).reading.clients.count
            ns.append(w6bUptimeNs() - t)
        }
        print("W6b bench gpuClients \(w6bPercentiles(ns)) clients=\(n)")
    }
}
