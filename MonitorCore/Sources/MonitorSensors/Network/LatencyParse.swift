import MonitorModel

/// Pure ICMP echo encoding / decoding for unprivileged `SOCK_DGRAM` + `IPPROTO_ICMP` sockets.
enum ICMPEcho {
    static let echoRequest: UInt8 = 8
    static let echoReply: UInt8 = 0

    /// RFC 1071 one's-complement checksum.
    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    /// Echo request: type 8, code 0, checksum, identifier, sequence (big-endian), `payload` filler bytes.
    static func request(identifier: UInt16, sequence: UInt16, payload: Int = 8) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 8 + max(0, payload))
        p[0] = echoRequest
        p[4] = UInt8(identifier >> 8)
        p[5] = UInt8(identifier & 0xFF)
        p[6] = UInt8(sequence >> 8)
        p[7] = UInt8(sequence & 0xFF)
        for i in 8..<p.count { p[i] = UInt8(truncatingIfNeeded: i) }
        let c = checksum(p)
        p[2] = UInt8(c >> 8)
        p[3] = UInt8(c & 0xFF)
        return p
    }

    /// Sequence number of an echo reply to `identifier` from `expectedSource` (IPv4, network order), or nil.
    /// macOS delivers DGRAM ICMP replies **with the IPv4 header** (`0x45…`): skip IHL×4 bytes first
    /// (docs/findings/extras.md §4). A header-less reply (another OS behaviour) is accepted too.
    static func replySequence(_ bytes: [UInt8], identifier: UInt16, source: UInt32, expectedSource: UInt32) -> UInt16? {
        guard source == expectedSource, !bytes.isEmpty else { return nil }
        var start = 0
        if bytes[0] >> 4 == 4 {
            let ihl = Int(bytes[0] & 0x0F) * 4
            guard ihl >= 20, bytes.count >= ihl else { return nil }
            if bytes.count > 9, bytes[9] != 1 { return nil } // IP protocol must be ICMP
            start = ihl
        }
        guard bytes.count >= start + 8, bytes[start] == echoReply, bytes[start + 1] == 0 else { return nil }
        let id = UInt16(bytes[start + 4]) << 8 | UInt16(bytes[start + 5])
        guard id == identifier else { return nil }
        return UInt16(bytes[start + 6]) << 8 | UInt16(bytes[start + 7])
    }
}

/// Rolling 5-minute window of probes → `LatencyReading`.
struct LatencyWindow: Sendable {
    struct Probe: Sendable, Equatable {
        var sentNs: UInt64
        var rttMs: Double?
    }

    static let spanNs: UInt64 = 300_000_000_000

    private(set) var probes: [Probe] = []
    /// RTT of the newest answered probe of the latest burst (nil if that whole burst was lost).
    private(set) var lastRTTms: Double?

    /// Records one burst (in send order) and drops probes older than 5 minutes before `nowNs`.
    mutating func record(burst: [Probe], nowNs: UInt64) {
        probes.append(contentsOf: burst)
        lastRTTms = burst.last(where: { $0.rttMs != nil })?.rttMs
        let cutoff = nowNs > Self.spanNs ? nowNs - Self.spanNs : 0
        probes.removeAll { $0.sentNs < cutoff }
    }

    func reading(target: String) -> LatencyReading {
        let rtts = probes.compactMap(\.rttMs)
        let loss = probes.isEmpty ? nil : Double(probes.count - rtts.count) / Double(probes.count)
        return LatencyReading(target: target, lastRTTms: lastRTTms, minMs: rtts.min(), avgMs: rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count),
                              maxMs: rtts.max(), lossFraction5m: loss)
    }
}
