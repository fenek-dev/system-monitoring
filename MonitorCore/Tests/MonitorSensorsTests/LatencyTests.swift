import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct LatencyParseTests {
    static let router: UInt32 = inet_addr("192.168.1.1")
    static let other: UInt32 = inet_addr("192.168.1.77")

    static func ipHeader(ihl: UInt8 = 5, proto: UInt8 = 1) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: Int(ihl) * 4)
        h[0] = 0x40 | ihl
        h[9] = proto
        return h
    }

    static func reply(id: UInt16, seq: UInt16, type: UInt8 = 0) -> [UInt8] {
        var r = ICMPEcho.request(identifier: id, sequence: seq)
        r[0] = type
        return r
    }

    @Test func requestLayoutAndChecksum() {
        let p = ICMPEcho.request(identifier: 0xBEEF, sequence: 0x0102)
        #expect(p.count == 16)
        #expect(Array(p[0..<2]) == [8, 0])
        #expect(Array(p[4..<8]) == [0xBE, 0xEF, 0x01, 0x02])
        #expect(ICMPEcho.checksum(p) == 0) // a packet including its checksum sums to 0
        #expect(ICMPEcho.checksum([0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7]) == ~UInt16(0xDDF2)) // RFC 1071 example
        #expect(ICMPEcho.checksum([0xFF]) == 0x00FF) // odd length
    }

    @Test func skipsIPv4HeaderUsingIHL() {
        let r = Self.reply(id: 7, seq: 42)
        #expect(ICMPEcho.replySequence(Self.ipHeader() + r, identifier: 7, source: Self.router, expectedSource: Self.router) == 42)
        // IP options: IHL 6 → 24-byte header.
        #expect(ICMPEcho.replySequence(Self.ipHeader(ihl: 6) + r, identifier: 7, source: Self.router, expectedSource: Self.router) == 42)
        // Header-less delivery is accepted too.
        #expect(ICMPEcho.replySequence(r, identifier: 7, source: Self.router, expectedSource: Self.router) == 42)
    }

    @Test func rejectsWrongIdentifierTypeSourceProtocolAndTruncation() {
        let r = Self.reply(id: 7, seq: 42)
        #expect(ICMPEcho.replySequence(Self.ipHeader() + r, identifier: 8, source: Self.router, expectedSource: Self.router) == nil)
        #expect(ICMPEcho.replySequence(Self.ipHeader() + Self.reply(id: 7, seq: 42, type: 8), identifier: 7,
                                       source: Self.router, expectedSource: Self.router) == nil) // our own request echoed
        #expect(ICMPEcho.replySequence(Self.ipHeader() + r, identifier: 7, source: Self.other, expectedSource: Self.router) == nil)
        #expect(ICMPEcho.replySequence(Self.ipHeader(proto: 17) + r, identifier: 7, source: Self.router, expectedSource: Self.router) == nil)
        #expect(ICMPEcho.replySequence(Array((Self.ipHeader() + r).prefix(26)), identifier: 7, source: Self.router,
                                       expectedSource: Self.router) == nil)
        var badIHL = Self.ipHeader() + r
        badIHL[0] = 0x43 // IHL 3 < 5
        #expect(ICMPEcho.replySequence(badIHL, identifier: 7, source: Self.router, expectedSource: Self.router) == nil)
        #expect(ICMPEcho.replySequence([], identifier: 7, source: Self.router, expectedSource: Self.router) == nil)
    }

    static let s: UInt64 = 1_000_000_000

    @Test func windowStatsAndLoss() {
        var w = LatencyWindow()
        #expect(w.reading(target: "r") == LatencyReading(target: "r"))
        w.record(burst: [.init(sentNs: 1 * Self.s, rttMs: 2), .init(sentNs: 1 * Self.s, rttMs: 4), .init(sentNs: 1 * Self.s, rttMs: nil)],
                 nowNs: 2 * Self.s)
        var r = w.reading(target: "r")
        #expect(r.lastRTTms == 4 && r.minMs == 2 && r.maxMs == 4 && r.avgMs == 3)
        #expect(abs((r.lossFraction5m ?? 0) - 1.0 / 3) < 1e-9)
        w.record(burst: [.init(sentNs: 11 * Self.s, rttMs: nil)], nowNs: 12 * Self.s)
        r = w.reading(target: "r")
        #expect(r.lastRTTms == nil) // latest burst fully lost
        #expect(r.lossFraction5m == 0.5)
    }

    @Test func windowEvictsAfterFiveMinutes() {
        var w = LatencyWindow()
        w.record(burst: [.init(sentNs: 10 * Self.s, rttMs: nil)], nowNs: 11 * Self.s)
        w.record(burst: [.init(sentNs: 305 * Self.s, rttMs: 3)], nowNs: 309 * Self.s) // cutoff 9 s: kept
        #expect(w.probes.count == 2)
        w.record(burst: [.init(sentNs: 320 * Self.s, rttMs: 5)], nowNs: 311 * Self.s) // cutoff 11 s: first dropped
        #expect(w.probes.count == 2)
        #expect(w.reading(target: "r").lossFraction5m == 0)
    }
}

@Suite struct LatencyRouterPickTests {
    static let en0 = DefaultRoute(gateway: "192.168.1.1", interfaceIndex: 14)
    static let en7 = DefaultRoute(gateway: "10.0.0.1", interfaceIndex: 22)
    static let utun = DefaultRoute(gateway: "10.8.0.1", interfaceIndex: 30)
    static let names: [UInt16: String] = [14: "en0", 22: "en7", 30: "utun4"]

    @Test func physicalPrimaryUsesItsOwnRoute() {
        let all = [Self.utun, Self.en7, Self.en0]
        #expect(RouteParse.physicalRouter(all, names: Self.names, primary: "en0", scRouter: nil) == .router("192.168.1.1"))
        #expect(RouteParse.physicalRouter(all, names: Self.names, primary: "en7", scRouter: nil) == .router("10.0.0.1"))
        // Primary's route missing from the dump → SystemConfiguration's router.
        #expect(RouteParse.physicalRouter([Self.utun], names: Self.names, primary: "en0", scRouter: "192.168.1.254")
            == .router("192.168.1.254"))
    }

    @Test func vpnPrimaryPingsThePhysicalRouter() {
        // Full-tunnel VPN: primary is utun, en0 keeps a scoped default route → ping en0's router, not 10.8.0.1.
        #expect(RouteParse.physicalRouter([Self.utun, Self.en0], names: Self.names, primary: "utun4", scRouter: "10.8.0.1")
            == .router("192.168.1.1"))
        #expect(RouteParse.physicalRouter([Self.utun, Self.en0], names: Self.names, primary: nil, scRouter: nil)
            == .router("192.168.1.1"))
    }

    @Test func onlyTunnelRoutesOrNothing() {
        #expect(RouteParse.physicalRouter([Self.utun], names: Self.names, primary: "utun4", scRouter: "10.8.0.1") == .vpnOnly)
        #expect(RouteParse.physicalRouter([Self.utun], names: Self.names, primary: nil, scRouter: nil) == .vpnOnly)
        #expect(RouteParse.physicalRouter([], names: [:], primary: "utun4", scRouter: nil) == .vpnOnly)
        #expect(RouteParse.physicalRouter([], names: [:], primary: nil, scRouter: nil) == .noRoute)
        #expect(RouteParse.physicalRouter([], names: [:], primary: "en0", scRouter: nil) == .noRoute)
        // Unnamed index (interface vanished) is not physical.
        #expect(RouteParse.physicalRouter([DefaultRoute(gateway: "1.1.1.1", interfaceIndex: 99)], names: Self.names,
                                          primary: nil, scRouter: nil) == .vpnOnly)
    }
}

/// Hermetic: ICMP to 127.0.0.1 (no network needed) and injected route states.
@Suite(.serialized) struct LatencyLoopbackTests {
    @Test func burstAgainstLoopback() throws {
        let r = LatencyBox.burst(target: "127.0.0.1", identifier: 0x7777, firstSequence: 65_534) // wraps past 65535
        let probes = try r.get()
        #expect(probes.count == LatencyBox.probesPerBurst)
        #expect(probes.allSatisfy { ($0.rttMs ?? -1) >= 0 && ($0.rttMs ?? 99) < 50 })
        #expect(zip(probes, probes.dropFirst()).allSatisfy { $1.sentNs - $0.sentNs >= 150_000_000 }) // ~200 ms schedule
    }

    @Test func badAddressFails() {
        #expect(throws: SensorError.self) { try LatencyBox.burst(target: "not-an-ip", identifier: 1, firstSequence: 0).get() }
    }

    @Test func probeRouteStates() async throws {
        var choice = RouterChoice.noRoute
        let probe = LatencyProbe(resolveRouter: { _ in choice })
        try probe.prepare()
        #expect(throws: SensorError.transient("No default route")) { try probe.sample(SampleContext()) }
        choice = .vpnOnly
        #expect(throws: SensorError.unavailable("VPN route")) { try probe.sample(SampleContext()) }
        choice = .router("127.0.0.1")
        let t0 = W6cClock.uptimeNs()
        let first = try probe.sample(SampleContext())
        #expect(W6cClock.uptimeNs() - t0 < 250_000_000) // doesn't wait for the burst
        #expect(first.reading == LatencyReading(target: "127.0.0.1"))
        // Task.sleep, not usleep: a parked cooperative thread starves other suites' GCD work.
        for _ in 0..<60 where probe.box.isInFlight { try await Task.sleep(for: .milliseconds(50)) }
        let r = try probe.sample(SampleContext()).reading
        #expect(r.target == "127.0.0.1" && r.lastRTTms != nil && r.lossFraction5m == 0)
        // Router change resets the window.
        for _ in 0..<60 where probe.box.isInFlight { try await Task.sleep(for: .milliseconds(50)) }
        choice = .router("127.0.0.2")
        #expect(try probe.sample(SampleContext()).reading == LatencyReading(target: "127.0.0.2"))
        for _ in 0..<60 where probe.box.isInFlight { try await Task.sleep(for: .milliseconds(50)) }
    }
}

/// `TELLTALE_HW_TESTS=1 scripts/test.sh LatencySmokeTests`.
@Suite(.enabled(if: W6cFixture.hardwareTests), .serialized)
struct LatencySmokeTests {
    @Test func matchesPingToRouter() throws {
        let probe = LatencyProbe()
        try probe.prepare()
        let t0 = W6cClock.uptimeNs()
        let first = try probe.sample(SampleContext())
        let sampleMs = W6cFixture.ms(W6cClock.uptimeNs() - t0)
        #expect(sampleMs < 250) // functional: never waits for the ~1.4 s burst (protocol bound 250 ms)
        let gw = try #require(try InterfaceSmokeTests.routeDefaultGateway())
        #expect(first.reading.target == gw)
        for _ in 0..<40 where probe.box.isInFlight { usleep(50_000) }
        let r = try probe.sample(SampleContext()).reading
        let ping = try W6cFixture.run(["/sbin/ping", "-c", "3", "-i", "0.2", gw])
        // "round-trip min/avg/max/stddev = 2.461/2.953/3.391/0.380 ms", "3 packets received"
        let stats = ping.split(separator: "\n").first { $0.contains("min/avg/max") }?
            .split(separator: "=").last?.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let pingAvg = try #require(stats?.dropFirst().first)
        print("W6c latency: \(r) sample() \(String(format: "%.2f", sampleMs)) ms; ping avg \(pingAvg) ms")
        let avg = try #require(r.avgMs)
        #expect(r.lastRTTms != nil)
        #expect(abs(avg - pingAvg) <= max(0.3 * pingAvg, 2))
        #expect((r.lossFraction5m ?? 1) <= 0.34)
        probe.invalidate()
    }
}
