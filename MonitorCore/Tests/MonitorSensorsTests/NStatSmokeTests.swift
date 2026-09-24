import CPrivate
import Darwin
import Foundation
import os
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// `TELLTALE_HW_TESTS=1 scripts/test.sh NStatSmokeTests` (soak: add `TELLTALE_SOAK=1`).
@Suite(.enabled(if: W6cFixture.hardwareTests), .serialized)
struct NStatSmokeTests {
    static let interactive = SampleContext(mode: .interactive)
    static let inspecting = SampleContext(mode: .interactive, demand: .connections)

    /// Returns a completed reading taken after a fresh query.
    static func fresh(_ s: NStatSensor, _ ctx: SampleContext = interactive) throws -> (reading: NetworkFlowsReading, capturedNs: UInt64) {
        let before = (try? s.sample(ctx))?.capturedNs ?? 0
        for _ in 0..<50 {
            usleep(20_000)
            let r = try s.sample(ctx)
            if r.capturedNs > before { return r }
        }
        throw SensorError.timeout
    }

    /// rx/tx of one pid: live flows + closed bytes (any start time).
    static func total(_ r: NetworkFlowsReading, pid: Int32) -> ByteCounts {
        var c = ByteCounts()
        for f in r.flows where f.process.pid == pid {
            c.rx += f.rxBytes
            c.tx += f.txBytes
        }
        for (k, v) in r.closedBytes where k.pid == pid {
            c.rx += v.rx
            c.tx += v.tx
        }
        return c
    }

    @Test func captureFixtures() throws {
        guard W6cFixture.capture else { return }
        let q = DispatchQueue(label: "capture")
        let box = CaptureBox()
        let undescribed = CaptureBox()
        let m = NStatManagerCreate(kCFAllocatorDefault, q) { src, _ in
            guard let src else { return }
            NStatSourceSetDescriptionBlock(src) { d in box.add(d) }
            NStatSourceSetCountsBlock(src) { d in undescribed.add(d) }
        }
        #expect(m != nil)
        guard let m else { return }
        NStatManagerAddAllTCP(m)
        NStatManagerAddAllUDP(m)
        sleep(1)
        let sem = DispatchSemaphore(value: 0)
        NStatManagerQueryAllSources(m) { sem.signal() }
        sem.wait()
        NStatManagerQueryAllSourcesDescriptions(m) { sem.signal() }
        sem.wait()
        let dicts = q.sync { box.dicts }
        // Keep a few described TCP and UDP sources + one never-described counts dict; drop names and UUIDs.
        var kept: [[String: Any]] = []
        if let raw = q.sync(execute: { undescribed.dicts }).first(where: { ($0["processID"] as? Int) == 0 }) { kept.append(raw) }
        for proto in ["TCP", "UDP"] {
            for d in dicts where (d["provider"] as? String) == proto && kept.count < (proto == "TCP" ? 7 : 13) {
                var c = d
                if c["processName"] != nil { c["processName"] = "proc" }
                for k in c.keys where k.lowercased().contains("uuid") { c[k] = nil }
                kept.append(c)
            }
        }
        let data = try PropertyListSerialization.data(fromPropertyList: kept, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: W6cFixture.sourceURL(""), withIntermediateDirectories: true)
        try data.write(to: W6cFixture.sourceURL("nstat_counts.plist"))
        NStatManagerDestroy(m)
    }

    @Test func availableAndReturnsFlows() throws {
        #expect(tt_nstat_available())
        let s = NStatSensor()
        try s.prepare()
        let r = try Self.fresh(s)
        print("W6c nstat: flows=\(r.reading.flows.count) closed=\(r.reading.closedBytes.count) " +
              "unattributed=\(r.reading.unattributedBytes) queryCost=\(W6cFixture.ms(s.box.lastQueryCostNs))ms")
        #expect(r.reading.flows.count > 5)
        #expect(r.reading.flows.allSatisfy { $0.remoteAddress == nil && $0.tcpState == nil }) // no endpoints without demand
        #expect(r.reading.flows.filter { $0.process.pid > 0 && $0.process.startTimeUs > 0 }.count * 2 > r.reading.flows.count)
        #expect(r.capturedNs <= W6cClock.uptimeNs())
        s.invalidate()
        #expect(throws: SensorError.self) { try s.sample(Self.interactive) }
        // Re-prepare after invalidate works (long-lived manager, but recoverable).
        try s.prepare()
        #expect(try Self.fresh(s).reading.flows.count > 5)
    }

    @Test func matchesNettopRateForLocalServer() throws {
        let server = try W6cFixture.startHTTPServer()
        defer { server.stop() }
        let s = NStatSensor()
        try s.prepare()
        let curl = try W6cFixture.spawn(["/usr/bin/curl", "-s", "--limit-rate", "4M", "-o", "/dev/null",
                                         "http://127.0.0.1:\(server.port)/big.bin"])
        defer { curl.terminate() }
        usleep(1_500_000)
        let a = try Self.fresh(s)
        let nA = try W6cFixture.nettopTotals()
        let tA = W6cClock.uptimeNs()
        usleep(3_000_000)
        let b = try Self.fresh(s)
        let nB = try W6cFixture.nettopTotals()
        let tB = W6cClock.uptimeNs()

        let ours = Double(W6cFixture.delta(Self.total(a.reading, pid: server.pid).tx, Self.total(b.reading, pid: server.pid).tx))
            / (Double(b.capturedNs - a.capturedNs) / 1e9)
        let theirs = Double(W6cFixture.delta(nA[server.pid]?.tx ?? 0, nB[server.pid]?.tx ?? 0)) / (Double(tB - tA) / 1e9)
        let curlOurs = Double(W6cFixture.delta(Self.total(a.reading, pid: curl.processIdentifier).rx,
                                               Self.total(b.reading, pid: curl.processIdentifier).rx))
            / (Double(b.capturedNs - a.capturedNs) / 1e9)
        print(String(format: "W6c nstat vs nettop: server tx ours %.2f MB/s nettop %.2f MB/s; curl rx ours %.2f MB/s",
                     ours / 1e6, theirs / 1e6, curlOurs / 1e6))
        #expect(theirs > 1e6)
        #expect(abs(ours - theirs) <= 0.3 * theirs)
        #expect(abs(curlOurs - ours) <= 0.3 * ours)
    }

    @Test func closedFlowsKeepTheirBytesAndEndpointsAppearOnDemand() throws {
        let server = try W6cFixture.startHTTPServer(bigMB: 32) // > socket buffers: stays Established while rate-limited
        defer { server.stop() }
        let s = NStatSensor()
        try s.prepare()
        _ = try Self.fresh(s)
        // Short-lived curls (new pid each) that open and close between two queries.
        var pids: [Int32] = []
        for _ in 0..<5 {
            let p = try W6cFixture.spawn(["/usr/bin/curl", "-s", "-o", "/dev/null", "http://127.0.0.1:\(server.port)/small.bin"])
            p.waitUntilExit()
            pids.append(p.processIdentifier)
        }
        usleep(300_000)
        let r = try Self.fresh(s).reading
        for pid in pids {
            let key = r.closedBytes.keys.first { $0.pid == pid }
            #expect(key != nil, "no closedBytes for curl \(pid)")
            if let key { #expect(r.closedBytes[key]!.rx >= 100 << 10, "curl \(pid) rx \(r.closedBytes[key]!.rx)") }
        }

        // Endpoints only with .connections.
        let long = try W6cFixture.spawn(["/usr/bin/curl", "-s", "--limit-rate", "200K", "-o", "/dev/null",
                                         "http://127.0.0.1:\(server.port)/big.bin"])
        defer { long.terminate() }
        usleep(500_000)
        _ = try s.sample(Self.inspecting) // turns endpoint parsing on for the next query
        let e = try Self.fresh(s, Self.inspecting).reading
        let flow = e.flows.first { $0.process.pid == long.processIdentifier && $0.proto == .tcp }
        #expect(flow?.remoteAddress == "127.0.0.1")
        #expect(flow?.remotePort == UInt16(server.port))
        #expect(flow?.tcpState == "Established")
        #expect(flow?.interface == "lo0")
        let off = try Self.fresh(s).reading
        #expect(off.flows.allSatisfy { $0.remoteAddress == nil })
    }

    @Test func benchQueryAndSample() throws {
        let s = NStatSensor()
        try s.prepare()
        _ = try Self.fresh(s)
        var queryMs: [Double] = []
        var sampleMs: [Double] = []
        for _ in 0..<30 {
            let t0 = W6cClock.uptimeNs()
            _ = try s.sample(Self.interactive)
            sampleMs.append(W6cFixture.ms(W6cClock.uptimeNs() - t0))
            usleep(50_000)
            queryMs.append(W6cFixture.ms(s.box.lastQueryCostNs))
        }
        let p = W6cFixture.percentile
        print(String(format: "W6c nstat bench: sample() p50 %.3f p95 %.3f ms; query p50 %.2f p95 %.2f ms",
                     p(sampleMs, 0.5), p(sampleMs, 0.95), p(queryMs, 0.5), p(queryMs, 0.95)))
        #expect(p(sampleMs, 0.95) < 5)
        #expect(p(queryMs, 0.95) < 250)
    }

    /// Steady-state CPU of an idle manager, then 3 min at background cadence under curl churn: CPU and RSS.
    @Test(.enabled(if: W6cFixture.soak)) func soakCPUAndRSS() throws {
        let server = try W6cFixture.startHTTPServer(bigMB: 1)
        defer { server.stop() }
        let s = NStatSensor()
        try s.prepare()
        _ = try Self.fresh(s)
        sleep(2)
        let c0 = W6cFixture.cpuTimeNs(), w0 = W6cClock.uptimeNs()
        sleep(10)
        let idlePct = Double(W6cFixture.cpuTimeNs() - c0) / Double(W6cClock.uptimeNs() - w0) * 100
        print(String(format: "W6c nstat idle manager CPU: %.3f %%", idlePct))

        let churn = try W6cFixture.spawn(["/bin/sh", "-c",
            "while true; do /usr/bin/curl -s -o /dev/null http://127.0.0.1:\(server.port)/small.bin; sleep 0.1; done"])
        defer { churn.terminate() }
        let rss0 = W6cFixture.residentBytes()
        let c1 = W6cFixture.cpuTimeNs(), w1 = W6cClock.uptimeNs()
        var lastReading = NetworkFlowsReading()
        for i in 1...18 {
            sleep(10) // background cadence
            lastReading = try s.sample(SampleContext(mode: .background)).reading
            if i % 3 == 0 {
                print("W6c soak t=\(i * 10)s rss=\(W6cFixture.residentBytes() >> 10)KB flows=\(lastReading.flows.count) " +
                      "closed=\(lastReading.closedBytes.count) queryCost=\(W6cFixture.ms(s.box.lastQueryCostNs))ms")
            }
        }
        let bgPct = Double(W6cFixture.cpuTimeNs() - c1) / Double(W6cClock.uptimeNs() - w1) * 100
        let growth = Int64(W6cFixture.residentBytes()) - Int64(rss0)
        print(String(format: "W6c soak: CPU %.3f %% (incl. callbacks under churn), RSS growth %lld KB", bgPct, growth >> 10))
        #expect(bgPct < 2)
        #expect(growth < 8 << 20)
    }
}

/// Collects raw counts dictionaries (as binary plists) on the capture queue.
final class CaptureBox: Sendable {
    private let lock = OSAllocatedUnfairLock<[Data]>(initialState: [])

    func add(_ d: CFDictionary?) {
        guard let d = d as? [String: Any],
              let data = try? PropertyListSerialization.data(fromPropertyList: d, format: .binary, options: 0) else { return }
        lock.withLock { $0.append(data) }
    }

    var dicts: [[String: Any]] {
        lock.withLock { $0 }.compactMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
    }
}
