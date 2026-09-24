import Darwin
import Dispatch
import MonitorModel
import os
import SystemConfiguration

/// Router latency / loss via unprivileged ICMP (`SOCK_DGRAM`, `IPPROTO_ICMP`; no root).
///
/// Each `sample()` (every 10 s) resolves the router of the **physical** primary interface (never a VPN gateway;
/// only tunnel routes → `.unavailable("VPN route")`) and starts a burst of 3 echoes, 200 ms apart on a fixed
/// schedule, on the box queue (≈1.4 s incl. 1 s grace). `sample()` never waits: it returns the last completed
/// burst's stats over a 5-minute window.
public final class LatencyProbe: Sensor {
    public typealias Reading = LatencyReading
    public let id: SensorID = .latency
    public let cadence: SensorCadence = .every(.seconds(10), background: .seconds(10))

    let box = LatencyBox()
    private var store: SCDynamicStore?
    /// Injectable for tests; default reads the routing table + SystemConfiguration.
    private let resolveRouter: ((SCDynamicStore?) -> RouterChoice)

    public convenience init() {
        self.init(resolveRouter: NetworkFFI.physicalRouter)
    }

    init(resolveRouter: @escaping (SCDynamicStore?) -> RouterChoice) {
        self.resolveRouter = resolveRouter
    }

    public func prepare() throws(SensorError) {
        if store == nil { store = NetworkFFI.makeStore("dev.telltale.latency") }
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: LatencyReading, capturedNs: UInt64) {
        let router: String
        switch resolveRouter(store) {
        case .router(let r): router = r
        case .vpnOnly:
            box.setTarget(nil)
            throw .unavailable("VPN route")
        case .noRoute:
            box.setTarget(nil)
            throw .transient("No default route")
        }
        box.setTarget(router)
        let last = box.last()
        if let err = last.error { box.startBurst(router); throw err }
        box.startBurst(router)
        return (last.reading ?? LatencyReading(target: router), last.capturedNs ?? W6cClock.uptimeNs())
    }

    public func invalidate() {
        store = nil
        box.setTarget(nil)
    }
}

/// Burst state (ARCHITECTURE §4): the queue does the blocking socket work; closures capture only the box.
final class LatencyBox: Sendable {
    struct State: Sendable {
        var target: String?
        var window = LatencyWindow()
        var inFlight = false
        var reading: LatencyReading?
        var capturedNs: UInt64?
        var error: SensorError?
        var sequence: UInt16 = 0
    }

    static let probesPerBurst = 3
    static let periodNs: UInt64 = 200_000_000
    static let graceNs: UInt64 = 1_000_000_000

    let queue = DispatchQueue(label: "dev.telltale.latency", qos: .utility)
    let lock = OSAllocatedUnfairLock(initialState: State())
    let identifier = UInt16.random(in: 1...UInt16.max)

    /// A new router resets the window.
    func setTarget(_ t: String?) {
        lock.withLock { s in
            guard s.target != t else { return }
            s.target = t
            s.window = LatencyWindow()
            s.reading = nil
            s.capturedNs = nil
            s.error = nil
        }
    }

    func last() -> (reading: LatencyReading?, capturedNs: UInt64?, error: SensorError?) {
        lock.withLock { ($0.reading, $0.capturedNs, $0.error) }
    }

    var isInFlight: Bool { lock.withLock { $0.inFlight } }

    func startBurst(_ target: String) {
        let firstSeq = lock.withLock { s -> UInt16? in
            guard !s.inFlight else { return nil }
            s.inFlight = true
            let first = s.sequence
            s.sequence &+= UInt16(Self.probesPerBurst)
            return first
        }
        guard let firstSeq else { return }
        queue.async { [self] in
            let result = Self.burst(target: target, identifier: identifier, firstSequence: firstSeq)
            let now = W6cClock.uptimeNs()
            lock.withLock { s in
                s.inFlight = false
                guard s.target == target else { return } // router changed meanwhile
                switch result {
                case .success(let probes):
                    s.window.record(burst: probes, nowNs: now)
                    s.reading = s.window.reading(target: target)
                    s.capturedNs = now
                    s.error = nil
                case .failure(let e):
                    s.error = e
                }
            }
        }
    }

    /// Blocking: sends `probesPerBurst` echoes on a fixed 200 ms schedule and collects verified replies.
    static func burst(target: String, identifier: UInt16, firstSequence: UInt16) -> Result<[LatencyWindow.Probe], SensorError> {
        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, target, &dest.sin_addr) == 1 else { return .failure(.transient("Bad router address")) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return .failure(.fromErrno("socket(SOCK_DGRAM, IPPROTO_ICMP)")) }
        defer { close(fd) }

        let n = probesPerBurst
        var sent = [UInt64](repeating: 0, count: n)
        var rtt = [Double?](repeating: nil, count: n)
        let start = W6cClock.uptimeNs()
        for k in 0..<n {
            let due = start + UInt64(k) * periodNs
            let now = W6cClock.uptimeNs()
            if due > now { usleep(useconds_t((due - now) / 1_000)) }
            let seq = firstSequence &+ UInt16(k)
            let packet = ICMPEcho.request(identifier: identifier, sequence: seq)
            sent[k] = W6cClock.uptimeNs()
            let rc = withUnsafePointer(to: &dest) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    packet.withUnsafeBytes { sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
            if rc < 0, k == 0, errno == EPERM || errno == EACCES { return .failure(.fromErrno("sendto ICMP")) }
            let deadline = k == n - 1 ? sent[k] + graceNs : start + UInt64(k + 1) * periodNs
            receive(fd, until: deadline, identifier: identifier, firstSequence: firstSequence,
                    expected: dest.sin_addr.s_addr, sent: sent, rtt: &rtt)
        }
        return .success((0..<n).map { LatencyWindow.Probe(sentNs: sent[$0], rttMs: rtt[$0]) })
    }

    /// Reads replies until `deadline` (poll-bounded), stamping each RTT the moment it is read.
    private static func receive(_ fd: Int32, until deadline: UInt64, identifier: UInt16, firstSequence: UInt16,
                                expected: in_addr_t, sent: [UInt64], rtt: inout [Double?]) {
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let now = W6cClock.uptimeNs()
            guard now < deadline else { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(min((deadline - now) / 1_000_000 + 1, 2_000))
            guard poll(&pfd, 1, waitMs) > 0 else { return }
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buf.withUnsafeMutableBytes { recvfrom(fd, $0.baseAddress, $0.count, MSG_DONTWAIT, sa, &fromLen) }
                }
            }
            let readNs = W6cClock.uptimeNs()
            guard got > 0 else { continue }
            guard let seq = ICMPEcho.replySequence(Array(buf.prefix(got)), identifier: identifier,
                                                    source: from.sin_addr.s_addr, expectedSource: expected) else { continue }
            let k = Int((UInt32(seq) + 0x1_0000 - UInt32(firstSequence)) & 0xFFFF) // modular offset, no wrapping ops
            guard k >= 0, k < rtt.count, sent[k] > 0, rtt[k] == nil, readNs >= sent[k] else { continue }
            rtt[k] = Double(readNs - sent[k]) / 1e6
        }
    }
}
