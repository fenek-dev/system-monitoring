import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Builders for synthetic routing-socket dumps.
enum RouteBytes {
    static func sin(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
        [16, UInt8(AF_INET), 0, 0, a, b, c, d] + [UInt8](repeating: 0, count: 8)
    }

    static func sin6() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 28)
        b[0] = 28
        b[1] = UInt8(AF_INET6)
        b[8] = 0xFE
        b[9] = 0x80
        b[23] = 1
        return b
    }

    /// 20-byte sockaddr_dl (a multiple of 4 but not of 8: the case 8-byte rounding gets wrong).
    static func sdl(_ name: String, index: UInt16) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        b[0] = 20
        b[1] = UInt8(AF_LINK)
        b[2] = UInt8(index & 0xFF)
        b[3] = UInt8(index >> 8)
        b[5] = UInt8(name.utf8.count)
        for (i, c) in name.utf8.enumerated() { b[8 + i] = c }
        return b
    }

    /// Pads each sockaddr to 4 bytes (sa_len 0 → 4 bytes), as XNU does.
    static func padded(_ sockaddrs: [[UInt8]]) -> [UInt8] {
        sockaddrs.flatMap { s in s + [UInt8](repeating: 0, count: RouteParse.roundUp32(Int(s.first ?? 0)) - s.count) }
    }

    static func route(index: UInt16, addrs: Int32, _ sockaddrs: [[UInt8]]) -> [UInt8] {
        var h = rt_msghdr()
        let body = padded(sockaddrs)
        h.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        h.rtm_version = UInt8(RTM_VERSION)
        h.rtm_type = UInt8(RTM_GET)
        h.rtm_index = index
        h.rtm_addrs = addrs
        h.rtm_flags = RTF_UP | RTF_GATEWAY
        return withUnsafeBytes(of: h) { Array($0) } + body
    }

    static func ifinfo(index: UInt16, name: String, flags: Int32, rx: UInt64, tx: UInt64, baud: UInt64) -> [UInt8] {
        var h = if_msghdr2()
        let body = padded([sdl(name, index: index)])
        h.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size + body.count)
        h.ifm_version = UInt8(RTM_VERSION)
        h.ifm_type = UInt8(RTM_IFINFO2)
        h.ifm_addrs = RTA_IFP
        h.ifm_flags = flags
        h.ifm_index = index
        h.ifm_data.ifi_ibytes = rx
        h.ifm_data.ifi_obytes = tx
        h.ifm_data.ifi_baudrate = baud
        return withUnsafeBytes(of: h) { Array($0) } + body
    }

    static func newaddr(index: UInt16, _ ifa: [UInt8]) -> [UInt8] {
        var h = ifa_msghdr()
        let netmask: [UInt8] = [5, 0, 0, 0, 0xFF] // short netmask: sa_len 5 → 8 bytes
        let body = padded([netmask, ifa])
        h.ifam_msglen = UInt16(MemoryLayout<ifa_msghdr>.size + body.count)
        h.ifam_version = UInt8(RTM_VERSION)
        h.ifam_type = UInt8(RTM_NEWADDR)
        h.ifam_addrs = RTA_NETMASK | RTA_IFA
        h.ifam_index = index
        return withUnsafeBytes(of: h) { Array($0) } + body
    }
}

@Suite struct InterfaceParseTests {
    @Test func roundUp32() {
        #expect([0, 1, 4, 5, 16, 20, 28].map(RouteParse.roundUp32) == [4, 4, 4, 8, 16, 20, 28])
    }

    static let dump: [UInt8] =
        // A: 20-byte link-layer destination, then the gateway: only 4-byte rounding lands on it.
        RouteBytes.route(index: 3, addrs: RTA_DST | RTA_GATEWAY | RTA_NETMASK,
                         [RouteBytes.sdl("en9", index: 3), RouteBytes.sin(10, 9, 9, 9), [0]])
        // B: default via 192.168.1.1 on index 4 (netmask sa_len 0).
        + RouteBytes.route(index: 4, addrs: RTA_DST | RTA_GATEWAY | RTA_NETMASK,
                           [RouteBytes.sin(0, 0, 0, 0), RouteBytes.sin(192, 168, 1, 1), [0]])
        // C: default with a link-layer gateway (bridge) → not an IPv4 gateway.
        + RouteBytes.route(index: 24, addrs: RTA_DST | RTA_GATEWAY | RTA_NETMASK,
                           [RouteBytes.sin(0, 0, 0, 0), RouteBytes.sdl("bridge100", index: 24), [0]])
        // D: VPN default via 10.8.0.1 on index 12.
        + RouteBytes.route(index: 12, addrs: RTA_DST | RTA_GATEWAY,
                           [RouteBytes.sin(0, 0, 0, 0), RouteBytes.sin(10, 8, 0, 1)])

    @Test func parsesRoutesWithRoundUp32() {
        let routes = Self.dump.withUnsafeBytes { RouteParse.routes($0) }
        #expect(routes.count == 4)
        #expect(routes[0].destinationFamily == AF_LINK)
        #expect(routes[0].gateway == "10.9.9.9")
        #expect(routes[2].gateway == nil)
    }

    @Test func defaultGatewaysAndVPNTieBreak() {
        let gws = Self.dump.withUnsafeBytes { RouteParse.defaultGateways($0) }
        #expect(gws == [DefaultRoute(gateway: "192.168.1.1", interfaceIndex: 4), DefaultRoute(gateway: "10.8.0.1", interfaceIndex: 12)])
        #expect(RouteParse.pick(gws, primaryIndex: 12)?.gateway == "10.8.0.1")
        #expect(RouteParse.pick(gws, primaryIndex: nil)?.gateway == "192.168.1.1")
        #expect(RouteParse.pick(gws, primaryIndex: 99)?.gateway == "192.168.1.1")
        #expect(RouteParse.pick([], primaryIndex: 4) == nil)
    }

    @Test func truncatedDumpsDoNotCrash() {
        for cut in [0, 3, 50, MemoryLayout<rt_msghdr>.size + 10, Self.dump.count - 1] {
            let part = Array(Self.dump.prefix(cut))
            _ = part.withUnsafeBytes { RouteParse.routes($0) }
            _ = part.withUnsafeBytes { InterfaceParse.interfaces($0) }
        }
        var zeroLen = Self.dump
        zeroLen[0] = 0
        zeroLen[1] = 0
        #expect(zeroLen.withUnsafeBytes { RouteParse.routes($0) }.isEmpty)
    }

    static let iflist: [UInt8] =
        RouteBytes.ifinfo(index: 1, name: "lo0", flags: IFF_UP | IFF_RUNNING | IFF_LOOPBACK, rx: 10, tx: 10, baud: 0)
        + RouteBytes.newaddr(index: 1, RouteBytes.sin(127, 0, 0, 1))
        + RouteBytes.ifinfo(index: 14, name: "en0", flags: IFF_UP | IFF_RUNNING, rx: 5_000_000_000, tx: 6_000_000_123,
                            baud: 1_200_000_000)
        + RouteBytes.newaddr(index: 14, RouteBytes.sin6()) // IPv6 first: skipped
        + RouteBytes.newaddr(index: 14, RouteBytes.sin(192, 168, 1, 64))
        + RouteBytes.newaddr(index: 14, RouteBytes.sin(10, 0, 0, 2)) // second IPv4: first one wins
        + RouteBytes.ifinfo(index: 20, name: "utun3", flags: IFF_UP | IFF_RUNNING, rx: 1, tx: 2, baud: 0)
        + RouteBytes.ifinfo(index: 7, name: "en5", flags: IFF_UP, rx: 0, tx: 0, baud: 0)

    @Test func parsesIFList2With64BitCounters() {
        let ifs = Self.iflist.withUnsafeBytes { InterfaceParse.interfaces($0) }
        #expect(ifs.map(\.name) == ["lo0", "en0", "utun3", "en5"])
        let en0 = ifs[1]
        #expect(en0.index == 14 && en0.rxBytes == 5_000_000_000 && en0.txBytes == 6_000_000_123) // > 2^32
        #expect(en0.ipv4 == "192.168.1.64")
        #expect(en0.baudRate == 1_200_000_000)
        #expect(en0.isUp && !en0.isLoopback)
        #expect(ifs[0].isLoopback && ifs[0].ipv4 == "127.0.0.1")
        #expect(!ifs[3].isUp) // UP but not RUNNING
    }

    @Test func kinds() {
        func d(_ type: String, _ name: String) -> InterfaceDescriptor { InterfaceDescriptor(bsdName: "x", displayName: name, type: type) }
        #expect(InterfaceParse.kind(d("IEEE80211", "Wi-Fi")) == .wifi)
        #expect(InterfaceParse.kind(d("Ethernet", "Ethernet")) == .ethernet)
        #expect(InterfaceParse.kind(d("Ethernet", "Thunderbolt Ethernet Slot 1")) == .thunderbolt)
        #expect(InterfaceParse.kind(d("Bridge", "Thunderbolt Bridge")) == .thunderbolt)
        #expect(InterfaceParse.kind(d("Ethernet", "iPhone USB")) == .cellular)
        #expect(InterfaceParse.kind(d("WWAN", "Cellular")) == .cellular)
        #expect(InterfaceParse.kind(d("Bridge", "bridge100")) == .other)
        #expect(InterfaceParse.kind(nil) == .other)
    }

    @Test func readingKeepsHardwareAndPrimaryOnly() {
        let ifs = Self.iflist.withUnsafeBytes { InterfaceParse.interfaces($0) }
        let sc = ["en0": InterfaceDescriptor(bsdName: "en0", displayName: "Wi-Fi", type: "IEEE80211"),
                  "en5": InterfaceDescriptor(bsdName: "en5", displayName: "Ethernet", type: "Ethernet"),
                  "lo0": InterfaceDescriptor(bsdName: "lo0", displayName: "Loopback", type: "Loopback")]
        let r = InterfaceParse.reading(ifs, descriptors: sc, primary: "en0", router: "192.168.1.1")
        #expect(r.interfaces.map(\.bsdName) == ["en0", "en5"])
        #expect(r.routerIPv4 == "192.168.1.1")
        let en0 = r.interfaces[0]
        #expect(en0.displayName == "Wi-Fi" && en0.kind == .wifi && en0.isPrimary && en0.isUp)
        #expect(en0.linkRateBps == 1_200_000_000 && en0.ipv4 == "192.168.1.64")
        #expect(r.interfaces[1].linkRateBps == nil && !r.interfaces[1].isPrimary)
        // VPN primary: the tunnel is included (kind .other) so the primary row exists.
        let vpn = InterfaceParse.reading(ifs, descriptors: sc, primary: "utun3", router: "10.8.0.1")
        #expect(vpn.interfaces.map(\.bsdName) == ["en0", "utun3", "en5"])
        #expect(vpn.interfaces[1].kind == .other && vpn.interfaces[1].isPrimary && vpn.interfaces[1].displayName == "utun3")
    }

    // MARK: captured dumps (TELLTALE_CAPTURE=1 InterfaceSmokeTests)

    @Test func parsesCapturedIFList2() throws {
        let dump = try W6cFixture.data("iflist2.bin")
        let ifs = dump.withUnsafeBytes { InterfaceParse.interfaces($0) }
        let netstat = try String(decoding: W6cFixture.data("netstat_ibn.txt"), as: UTF8.self)
        let ref = InterfaceSmokeTests.netstatLinkRows(netstat)
        #expect(ifs.count >= 3)
        #expect(Set(ifs.map(\.name)) == Set(ref.keys))
        #expect(ifs.first { $0.name == "lo0" }?.ipv4 == "127.0.0.1")
        // IFLIST2 byte counters are truncated to 32 bits for unprivileged callers: no counter check here.
        #expect(ifs.allSatisfy { $0.rxBytes <= UInt64(UInt32.max) })
    }

    @Test func parsesIFMIBData() {
        var d = ifmibdata()
        d.ifmd_data.ifi_ibytes = 970_742_642_131
        d.ifmd_data.ifi_obytes = 27_528_499_530
        d.ifmd_data.ifi_baudrate = 1_000_000_000
        let bytes = withUnsafeBytes(of: d) { Array($0) }
        let c = bytes.withUnsafeBytes { InterfaceParse.ifmib($0) }
        #expect(c?.rx == 970_742_642_131 && c?.tx == 27_528_499_530 && c?.baudRate == 1_000_000_000)
        #expect(Array(bytes.dropLast()).withUnsafeBytes { InterfaceParse.ifmib($0) } == nil)
    }

    /// IFMIB dumps captured next to `netstat -ibn`: full 64-bit counters match netstat's.
    @Test func parsesCapturedIFMIB() throws {
        let plist = try #require(try PropertyListSerialization.propertyList(from: W6cFixture.data("ifmib.plist"), format: nil)
            as? [String: Data])
        let ref = InterfaceSmokeTests.netstatLinkRows(String(decoding: try W6cFixture.data("netstat_ibn.txt"), as: UTF8.self))
        #expect(plist.count >= 3)
        var big = 0
        for (name, data) in plist {
            let c = try #require(data.withUnsafeBytes { InterfaceParse.ifmib($0) })
            let r = try #require(ref[name], "\(name) not in netstat")
            #expect(InterfaceSmokeTests.near(c.rx, r.rx, 0.01), "\(name) rx \(c.rx) vs \(r.rx)")
            #expect(InterfaceSmokeTests.near(c.tx, r.tx, 0.01), "\(name) tx \(c.tx) vs \(r.tx)")
            if c.rx > UInt64(UInt32.max) || c.tx > UInt64(UInt32.max) { big += 1 }
        }
        print("W6c ifmib fixture: \(plist.count) interfaces, \(big) with counters > 2^32")
    }

    @Test func parsesCapturedDefaultRoute() throws {
        let dump = try W6cFixture.data("route_flags_gateway.bin")
        let expected = try String(decoding: W6cFixture.data("route_default.txt"), as: UTF8.self)
            .split(separator: "\n").first { $0.contains("gateway:") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
        let gws = dump.withUnsafeBytes { RouteParse.defaultGateways($0) }
        #expect(!gws.isEmpty)
        #expect(gws.map(\.gateway).contains(try #require(expected)))
    }
}
