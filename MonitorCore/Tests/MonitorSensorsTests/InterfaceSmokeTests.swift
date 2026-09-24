import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// `TELLTALE_HW_TESTS=1 scripts/test.sh InterfaceSmokeTests` (fixture capture: add `TELLTALE_CAPTURE=1`).
@Suite(.enabled(if: W6cFixture.hardwareTests), .serialized)
struct InterfaceSmokeTests {
    /// `netstat -ibn` link rows → name → (Ibytes, Obytes). The Address column is empty for some interfaces.
    static func netstatLinkRows(_ text: String) -> [String: (rx: UInt64, tx: UInt64)] {
        var out: [String: (UInt64, UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 10, f[2].hasPrefix("<Link#") else { continue }
            let (i, o) = f.count >= 11 ? (6, 9) : (5, 8)
            guard let rx = UInt64(f[i]), let tx = UInt64(f[o]) else { continue }
            out[String(f[0]).replacingOccurrences(of: "*", with: "")] = (rx, tx)
        }
        return out
    }

    static func near(_ a: UInt64, _ b: UInt64, _ frac: Double, slack: Double = 65_536) -> Bool {
        abs(Double(a) - Double(b)) <= frac * Double(max(a, b)) + slack
    }

    static func routeDefaultGateway() throws -> String? {
        try W6cFixture.run(["/sbin/route", "-n", "get", "default"]).split(separator: "\n")
            .first { $0.contains("gateway:") }?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
    }

    @Test func captureFixtures() throws {
        guard W6cFixture.capture else { return }
        var buf: [UInt8] = []
        let n = try NetworkFFI.sysctlDump([CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0], into: &buf, context: "iflist2")
        let ifs = buf.withUnsafeBytes { InterfaceParse.interfaces(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        var mib: [String: Data] = [:]
        for i in ifs { if let b = NetworkFFI.ifmibBytes(index: i.index) { mib[i.name] = Data(b) } }
        let netstat = try W6cFixture.run(["/usr/sbin/netstat", "-ibn"])
        try PropertyListSerialization.data(fromPropertyList: mib, format: .binary, options: 0)
            .write(to: W6cFixture.sourceURL("ifmib.plist"))
        try Data(buf.prefix(n)).write(to: W6cFixture.sourceURL("iflist2.bin"))
        try Data(netstat.utf8).write(to: W6cFixture.sourceURL("netstat_ibn.txt"))
        var rbuf: [UInt8] = []
        let rn = try NetworkFFI.sysctlDump([CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY], into: &rbuf, context: "rt")
        try Data(rbuf.prefix(rn)).write(to: W6cFixture.sourceURL("route_flags_gateway.bin"))
        let route = try W6cFixture.run(["/sbin/route", "-n", "get", "default"])
        try Data(route.utf8).write(to: W6cFixture.sourceURL("route_default.txt"))
    }

    @Test func matchesNetstatAndRoute() throws {
        let s = InterfaceSensor()
        try s.prepare()
        let r = try s.sample(SampleContext()).reading
        let ref = Self.netstatLinkRows(try W6cFixture.run(["/usr/sbin/netstat", "-ibn"]))
        let gw = try Self.routeDefaultGateway()
        for i in r.interfaces {
            print("W6c if: \(i.bsdName) \(i.displayName) \(i.kind) up=\(i.isUp) primary=\(i.isPrimary) " +
                  "rx=\(i.rxBytes) tx=\(i.txBytes) ipv4=\(i.ipv4 ?? "-") link=\(i.linkRateBps.map { "\($0 / 1e6)M" } ?? "-")")
            let n = try #require(ref[i.bsdName], "\(i.bsdName) missing from netstat")
            #expect(Self.near(i.rxBytes, n.rx, 0.01), "\(i.bsdName) rx \(i.rxBytes) vs netstat \(n.rx)")
            #expect(Self.near(i.txBytes, n.tx, 0.01), "\(i.bsdName) tx \(i.txBytes) vs netstat \(n.tx)")
        }
        print("W6c if: router=\(r.routerIPv4 ?? "nil") route(8)=\(gw ?? "nil")")
        let primary = try #require(r.interfaces.first { $0.isPrimary })
        #expect(primary.isUp && primary.ipv4 != nil)
        #expect(!r.interfaces.contains { $0.bsdName == "lo0" })
        #expect(r.routerIPv4 == gw)
    }

    @Test func rateMatchesNetstatDelta() throws {
        let s = InterfaceSensor()
        try s.prepare()
        let a = try s.sample(SampleContext())
        let na = Self.netstatLinkRows(try W6cFixture.run(["/usr/sbin/netstat", "-ibn"]))
        sleep(3)
        let b = try s.sample(SampleContext())
        let nb = Self.netstatLinkRows(try W6cFixture.run(["/usr/sbin/netstat", "-ibn"]))
        for i in b.reading.interfaces where i.isUp {
            guard let ia = a.reading.interfaces.first(where: { $0.bsdName == i.bsdName }),
                  let x = na[i.bsdName], let y = nb[i.bsdName] else { continue }
            let ours = W6cFixture.delta(ia.rxBytes, i.rxBytes), theirs = W6cFixture.delta(x.rx, y.rx)
            print("W6c if delta \(i.bsdName): rx ours \(ours) netstat \(theirs)")
            #expect(Self.near(ours, theirs, 0.3, slack: 50_000))
        }
    }

    @Test func bench() throws {
        let s = InterfaceSensor()
        try s.prepare()
        _ = try s.sample(SampleContext())
        var ms: [Double] = []
        for _ in 0..<30 {
            let t0 = W6cClock.uptimeNs()
            _ = try s.sample(SampleContext())
            ms.append(W6cFixture.ms(W6cClock.uptimeNs() - t0))
        }
        let t0 = W6cClock.uptimeNs()
        _ = NetworkFFI.descriptors()
        let g = NetworkFFI.globalIPv4(NetworkFFI.makeStore("bench"))
        _ = NetworkFFI.router(primary: g.primary, scRouter: g.router)
        let slow = W6cFixture.ms(W6cClock.uptimeNs() - t0)
        print(String(format: "W6c if bench: sample() p50 %.3f p95 %.3f ms; slow refresh %.2f ms",
                     W6cFixture.percentile(ms, 0.5), W6cFixture.percentile(ms, 0.95), slow))
        #expect(W6cFixture.percentile(ms, 0.95) < 5)
    }
}
