import Foundation
import MonitorModel

/// Endpoint fields of one NStat source; parsed only while `.connections` is demanded.
struct NStatEndpoints: Sendable, Equatable {
    var localPort: UInt16?
    var remoteAddress: String?
    var remotePort: UInt16?
    var tcpState: String?
    var interfaceIndex: UInt32?
}

/// One NStat source dictionary (description and counts have the same shape) decoded to plain values.
struct NStatSourceSample: Sendable, Equatable {
    var pid: Int32?
    var uniquePID: UInt64?
    var effectivePID: Int32?
    var processName: String?
    var proto: TransportProtocol = .other
    var rxBytes: UInt64?
    var txBytes: UInt64?
    var endpoints: NStatEndpoints?
}

/// Dictionary key names. Defaults are the names verified in docs/findings/nstat.md; `refine` re-discovers any
/// that a future OS renames (case-insensitive, with exclusions so `uniqueProcessID` never passes for the pid).
struct NStatKeyMap: Sendable, Equatable {
    var pid = "processID"
    var uniquePID = "uniqueProcessID"
    var effectivePID = "epid"
    var name = "processName"
    var provider = "provider"
    var rx = "rxBytes"
    var tx = "txBytes"
    var local = "localAddress"
    var remote = "remoteAddress"
    var state = "TCPState"
    var interface = "interface"

    private static let mediumQualifiers = ["wifi", "cellular", "wired", "duplicate", "outoforder", "retransmitted"]

    /// Replaces each name absent from `keys` by a discovered one. Returns true if anything changed.
    mutating func refine(with keys: [String]) -> Bool {
        let lowered = keys.map { ($0, $0.lowercased()) }
        let present = Set(keys)
        func find(_ current: String, exact: [String], contains needle: String?, excluding: [String] = []) -> String {
            guard !present.contains(current) else { return current }
            if let hit = lowered.first(where: { exact.contains($0.1) }) { return hit.0 }
            if let needle, let hit = lowered.first(where: { k in
                k.1.contains(needle) && !excluding.contains { k.1.contains($0) }
            }) { return hit.0 }
            return current
        }
        let before = self
        pid = find(pid, exact: ["processid", "pid"], contains: "processid", excluding: ["unique"])
        uniquePID = find(uniquePID, exact: ["uniqueprocessid", "upid"], contains: "uniqueprocess")
        effectivePID = find(effectivePID, exact: ["epid", "effectivepid"], contains: nil)
        name = find(name, exact: ["processname"], contains: "processname")
        provider = find(provider, exact: ["provider"], contains: "provider")
        rx = find(rx, exact: ["rxbytes"], contains: "rxbytes", excluding: Self.mediumQualifiers)
        tx = find(tx, exact: ["txbytes"], contains: "txbytes", excluding: Self.mediumQualifiers)
        local = find(local, exact: ["localaddress"], contains: "localaddr")
        remote = find(remote, exact: ["remoteaddress"], contains: "remoteaddr")
        state = find(state, exact: ["tcpstate"], contains: "state")
        interface = find(interface, exact: ["interface"], contains: "interface")
        return self != before
    }
}

enum NStatParse {
    /// XNU `<netinet/tcp_fsm.h>` order.
    private static let tcpStates = ["Closed", "Listen", "SynSent", "SynReceived", "Established", "CloseWait",
                                    "FinWait1", "Closing", "LastAck", "FinWait2", "TimeWait"]

    static func tcpStateName(_ raw: Int) -> String? {
        tcpStates.indices.contains(raw) ? tcpStates[raw] : nil
    }

    /// macOS 26 reports `TCPState` as a string ("Established"); older builds as a `tcp_fsm.h` number.
    static func tcpState(_ v: Any?) -> String? {
        if let s = v as? String { return s.isEmpty ? nil : s }
        if let n = v as? NSNumber { return tcpStateName(n.intValue) }
        return nil
    }

    static func transport(_ provider: String?) -> TransportProtocol {
        guard let p = provider?.lowercased() else { return .other }
        if p.contains("quic") { return .quic }
        if p.contains("tcp") { return .tcp }
        if p.contains("udp") { return .udp }
        return .other
    }

    /// `value(key)` reads the source dictionary; any wrong-typed value becomes nil.
    static func sample(_ value: (String) -> Any?, keys: NStatKeyMap, endpoints: Bool) -> NStatSourceSample {
        func number(_ k: String) -> NSNumber? { value(k) as? NSNumber }
        var s = NStatSourceSample()
        s.pid = number(keys.pid).map { $0.int32Value }
        s.uniquePID = number(keys.uniquePID).map { $0.uint64Value }
        s.effectivePID = number(keys.effectivePID).map { $0.int32Value }
        s.processName = value(keys.name) as? String
        s.proto = transport(value(keys.provider) as? String)
        s.rxBytes = number(keys.rx).map { $0.uint64Value }
        s.txBytes = number(keys.tx).map { $0.uint64Value }
        // A counts callback for a source that has never been described carries processID 0 and no name:
        // identity unknown (only a description query fills it in). pid 0 with a name is the kernel.
        if s.pid == 0, s.processName?.isEmpty ?? true { s.pid = nil }
        if let p = s.pid, p < 0 { s.pid = nil }
        if s.uniquePID == 0 { s.uniquePID = nil }
        if s.effectivePID == 0 { s.effectivePID = nil }
        guard endpoints else { return s }
        let local = (value(keys.local) as? Data).flatMap(decode)
        let remote = (value(keys.remote) as? Data).flatMap(decode)
        s.endpoints = NStatEndpoints(
            localPort: local?.port,
            remoteAddress: remote?.address,
            remotePort: remote?.address == nil ? nil : remote?.port,
            tcpState: s.proto == .tcp ? tcpState(value(keys.state)) : nil,
            interfaceIndex: number(keys.interface).map { $0.uint32Value }
        )
        return s
    }

    private static func decode(_ data: Data) -> NetEndpoint? {
        data.withUnsafeBytes { NetSockaddr.decode($0) }
    }
}
