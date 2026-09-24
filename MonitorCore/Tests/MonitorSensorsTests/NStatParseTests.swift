import Darwin
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct NStatParseTests {
    // sa_len=16, AF_INET, port 443, 160.79.104.10
    static let v4: [UInt8] = [0x10, 0x02, 0x01, 0xBB, 160, 79, 104, 10, 0, 0, 0, 0, 0, 0, 0, 0]

    static func v6(_ addr: [UInt8], port: UInt16) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 28)
        b[0] = 28
        b[1] = UInt8(AF_INET6)
        b[2] = UInt8(port >> 8)
        b[3] = UInt8(port & 0xFF)
        for (i, v) in addr.enumerated() { b[8 + i] = v }
        return b
    }

    @Test func decodesIPv4() {
        #expect(NetSockaddr.decode(Self.v4) == NetEndpoint(address: "160.79.104.10", port: 443))
    }

    @Test func decodesIPv6AndMappedIPv4() {
        var loop = [UInt8](repeating: 0, count: 16)
        loop[15] = 1
        #expect(NetSockaddr.decode(Self.v6(loop, port: 8080)) == NetEndpoint(address: "::1", port: 8080))
        let mapped: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 1, 2, 3, 4]
        #expect(NetSockaddr.decode(Self.v6(mapped, port: 53)) == NetEndpoint(address: "1.2.3.4", port: 53))
    }

    @Test func wildcardHasNoAddress() {
        let any: [UInt8] = [0x10, 0x02, 0xE8, 0xF7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        #expect(NetSockaddr.decode(any) == NetEndpoint(address: nil, port: 59639))
        #expect(NetSockaddr.decode(Self.v6([UInt8](repeating: 0, count: 16), port: 0)) == NetEndpoint(address: nil, port: 0))
    }

    @Test func rejectsTruncatedAndUnknown() {
        #expect(NetSockaddr.decode(Array(Self.v4.prefix(7))) == nil)
        #expect(NetSockaddr.decode(Array(Self.v6([UInt8](repeating: 1, count: 16), port: 1).prefix(20))) == nil)
        var unix = Self.v4
        unix[1] = UInt8(AF_UNIX)
        #expect(NetSockaddr.decode(unix) == nil)
        #expect(NetSockaddr.decode([]) == nil)
        // sa_len claims more than the buffer holds
        var lying = Self.v4
        lying[0] = 64
        #expect(NetSockaddr.decode(lying) == nil)
    }

    @Test func transportAndState() {
        #expect(NStatParse.transport("TCP") == .tcp)
        #expect(NStatParse.transport("udp") == .udp)
        #expect(NStatParse.transport("QUIC") == .quic)
        #expect(NStatParse.transport(nil) == .other)
        #expect(NStatParse.tcpStateName(4) == "Established")
        #expect(NStatParse.tcpStateName(10) == "TimeWait")
        #expect(NStatParse.tcpStateName(11) == nil)
        #expect(NStatParse.tcpStateName(-1) == nil)
    }

    static func dict(tcp: Bool = true) -> [String: Any] {
        var d: [String: Any] = [
            "processID": NSNumber(value: 58909), "uniqueProcessID": NSNumber(value: 123_456_789 as UInt64),
            "epid": NSNumber(value: 58909), "processName": "claude", "provider": tcp ? "TCP" : "UDP",
            "rxBytes": NSNumber(value: 1_000 as UInt64), "txBytes": NSNumber(value: 250 as UInt64),
            "rxWiFiBytes": NSNumber(value: 7), "txRetransmittedBytes": NSNumber(value: 9),
            "localAddress": Data([0x10, 0x02, 0xD4, 0x19, 192, 168, 1, 64, 0, 0, 0, 0, 0, 0, 0, 0]),
            "remoteAddress": Data(v4), "interface": NSNumber(value: 11),
        ]
        if tcp { d["TCPState"] = NSNumber(value: 4) }
        return d
    }

    @Test func parsesCountsWithoutEndpoints() {
        let d = Self.dict()
        let s = NStatParse.sample({ d[$0] }, keys: NStatKeyMap(), endpoints: false)
        #expect(s.pid == 58909)
        #expect(s.uniquePID == 123_456_789)
        #expect(s.effectivePID == 58909)
        #expect(s.processName == "claude")
        #expect(s.proto == .tcp)
        #expect(s.rxBytes == 1_000 && s.txBytes == 250)
        #expect(s.endpoints == nil)
    }

    @Test func parsesEndpointsWhenRequested() {
        let d = Self.dict()
        let s = NStatParse.sample({ d[$0] }, keys: NStatKeyMap(), endpoints: true)
        #expect(s.endpoints == NStatEndpoints(localPort: 54297, remoteAddress: "160.79.104.10", remotePort: 443,
                                              tcpState: "Established", interfaceIndex: 11))
        let u = Self.dict(tcp: false)
        let us = NStatParse.sample({ u[$0] }, keys: NStatKeyMap(), endpoints: true)
        #expect(us.proto == .udp)
        #expect(us.endpoints?.tcpState == nil)
    }

    /// Counts for a never-described source: processID 0, no name → identity unknown (observed on macOS 26).
    @Test func undescribedSourceHasNoIdentity() {
        let d: [String: Any] = ["processID": NSNumber(value: 0), "uniqueProcessID": NSNumber(value: 0), "epid": NSNumber(value: 0),
                                "provider": "TCP", "rxBytes": NSNumber(value: 1_277_430), "txBytes": NSNumber(value: 84)]
        let s = NStatParse.sample({ d[$0] }, keys: NStatKeyMap(), endpoints: false)
        #expect(s.pid == nil && s.uniquePID == nil && s.effectivePID == nil)
        #expect(s.rxBytes == 1_277_430)
        var kernel = d
        kernel["processName"] = "kernel_task"
        #expect(NStatParse.sample({ kernel[$0] }, keys: NStatKeyMap(), endpoints: false).pid == 0)
    }

    /// Real dictionaries captured on macOS 26 (`TELLTALE_CAPTURE=1`, NStatSmokeTests.captureFixtures).
    @Test func parsesCapturedDictionaries() throws {
        let data = try W6cFixture.data("nstat_counts.plist")
        let dicts = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]])
        #expect(dicts.count >= 5)
        var described = 0, tcpWithState = 0, withRemote = 0
        for d in dicts {
            let s = NStatParse.sample({ d[$0] }, keys: NStatKeyMap(), endpoints: true)
            #expect(s.rxBytes != nil && s.txBytes != nil)
            #expect(s.proto == .tcp || s.proto == .udp)
            guard (d["processID"] as? Int ?? 0) != 0 else {
                #expect(s.pid == nil)
                continue
            }
            described += 1
            #expect(s.pid != nil && s.uniquePID != nil)
            if s.proto == .tcp, s.endpoints?.tcpState != nil { tcpWithState += 1 }
            if s.endpoints?.remoteAddress != nil { withRemote += 1 }
            #expect(s.endpoints?.localPort != nil)
        }
        #expect(described >= 5)
        #expect(tcpWithState >= 1)
        #expect(withRemote >= 1)
        var keys = NStatKeyMap()
        let changed = keys.refine(with: Array(dicts[dicts.count - 1].keys))
        #expect(!changed)
    }

    @Test func badTypesBecomeNil() {
        let d: [String: Any] = ["processID": "nope", "rxBytes": Data([1]), "provider": NSNumber(value: 3), "remoteAddress": "x"]
        let s = NStatParse.sample({ d[$0] }, keys: NStatKeyMap(), endpoints: true)
        #expect(s.pid == nil && s.rxBytes == nil && s.proto == .other)
        #expect(s.endpoints?.remoteAddress == nil)
    }

    @Test func keyMapDiscoversRenamedKeys() {
        var keys = NStatKeyMap()
        let renamed = ["kProcessID", "kUniqueProcessID", "epid", "kProcessName", "kProvider", "kRxBytes", "kRxWiFiBytes",
                       "kTxBytes", "kTxRetransmittedBytes", "kRemoteAddress", "kLocalAddress", "kTCPState", "kInterface"]
        let changed = keys.refine(with: renamed)
        #expect(changed)
        #expect(keys.pid == "kProcessID")
        #expect(keys.uniquePID == "kUniqueProcessID")
        #expect(keys.rx == "kRxBytes")
        #expect(keys.tx == "kTxBytes")
        #expect(keys.remote == "kRemoteAddress")
        #expect(keys.state == "kTCPState")
        #expect(keys.interface == "kInterface")
        // Already-correct names stay; a second pass changes nothing.
        let again = keys.refine(with: renamed)
        #expect(!again)
        var canonical = NStatKeyMap()
        let canonicalChanged = canonical.refine(with: Array(Self.dict().keys))
        #expect(!canonicalChanged)
        #expect(canonical == NStatKeyMap())
    }
}
