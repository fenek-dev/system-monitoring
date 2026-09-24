import Darwin
import Dispatch
import os

/// Non-blocking reverse DNS for connection rows (`ConnectionSample.remoteHost`).
///
/// `name(for:)` only reads the cache under a lock: a hit returns the name, a miss returns nil and queues an async
/// `getnameinfo` (at most `maxConcurrent` in flight, `maxPending` queued; extra requests are dropped and retried on a
/// later call). Results — including "no name" — are cached LRU (512) with a 10-minute TTL. Lookups only happen
/// while something asks, i.e. while connections are shown (never in background).
public final class ReverseDNS: Sendable {
    struct State: Sendable {
        var cache: ReverseDNSCache
        var jobs: ReverseDNSJobs
    }

    private let queue = DispatchQueue(label: "dev.telltale.rdns", qos: .utility, attributes: .concurrent)
    private let lock: OSAllocatedUnfairLock<State>
    private let resolve: @Sendable (String) -> String?
    private let now: @Sendable () -> UInt64

    public convenience init() {
        self.init(resolve: ReverseDNSLookup.hostName, now: W6cClock.uptimeNs)
    }

    init(capacity: Int = 512, ttlNs: UInt64 = 600_000_000_000, maxConcurrent: Int = 4, maxPending: Int = 128,
         resolve: @escaping @Sendable (String) -> String?, now: @escaping @Sendable () -> UInt64) {
        self.resolve = resolve
        self.now = now
        lock = OSAllocatedUnfairLock(initialState: State(
            cache: ReverseDNSCache(capacity: capacity, ttlNs: ttlNs),
            jobs: ReverseDNSJobs(maxConcurrent: maxConcurrent, maxPending: maxPending)
        ))
    }

    /// Cached host name for an IP literal; nil while unknown (a lookup is scheduled) or when it has none.
    public func name(for address: String) -> String? {
        let t = now()
        let hit = lock.withLock { s -> ReverseDNSCache.Lookup in
            let r = s.cache.lookup(address, nowNs: t)
            if r == .miss { s.jobs.request(address) }
            return r
        }
        if case .hit(let name) = hit { return name }
        pump()
        return nil
    }

    /// Batch form of `name(for:)`: only resolved addresses appear in the result.
    public func names(for addresses: some Sequence<String>) -> [String: String] {
        var out: [String: String] = [:]
        for a in addresses where out[a] == nil {
            if let n = name(for: a) { out[a] = n }
        }
        return out
    }

    var inFlightCount: Int { lock.withLock { $0.jobs.inFlight.count } }
    var cacheCount: Int { lock.withLock { $0.cache.count } }

    private func pump() {
        let started = lock.withLock { s -> [String] in
            var out: [String] = []
            while let a = s.jobs.next() { out.append(a) }
            return out
        }
        for address in started {
            queue.async { [self] in
                let name = resolve(address)
                let t = now()
                lock.withLock { s in
                    s.cache.store(address, name: name, nowNs: t)
                    s.jobs.finish(address)
                }
                pump()
            }
        }
    }
}

/// Pure LRU + TTL cache of reverse lookups (negative results cached too).
struct ReverseDNSCache: Sendable {
    enum Lookup: Sendable, Equatable {
        case hit(String?)
        case miss
    }

    private struct Entry: Sendable {
        var name: String?
        var expiresNs: UInt64
        var lastUse: UInt64
    }

    let capacity: Int
    let ttlNs: UInt64
    private var entries: [String: Entry] = [:]
    private var useCounter: UInt64 = 0

    init(capacity: Int, ttlNs: UInt64) {
        self.capacity = max(1, capacity)
        self.ttlNs = ttlNs
    }

    var count: Int { entries.count }

    mutating func lookup(_ address: String, nowNs: UInt64) -> Lookup {
        guard var e = entries[address] else { return .miss }
        guard nowNs < e.expiresNs else {
            entries[address] = nil
            return .miss
        }
        useCounter += 1
        e.lastUse = useCounter
        entries[address] = e
        return .hit(e.name)
    }

    mutating func store(_ address: String, name: String?, nowNs: UInt64) {
        useCounter += 1
        let (exp, overflow) = nowNs.addingReportingOverflow(ttlNs)
        entries[address] = Entry(name: name, expiresNs: overflow ? .max : exp, lastUse: useCounter)
        while entries.count > capacity, let lru = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries[lru] = nil
        }
    }
}

/// Pure bookkeeping of queued / in-flight lookups.
struct ReverseDNSJobs: Sendable {
    let maxConcurrent: Int
    let maxPending: Int
    private(set) var pending: [String] = []
    private var pendingSet: Set<String> = []
    private(set) var inFlight: Set<String> = []

    init(maxConcurrent: Int, maxPending: Int) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxPending = max(0, maxPending)
    }

    /// Queues an address unless it's already queued / in flight or the queue is full. Returns true if queued.
    @discardableResult
    mutating func request(_ address: String) -> Bool {
        guard !inFlight.contains(address), !pendingSet.contains(address), pending.count < maxPending else { return false }
        pending.append(address)
        pendingSet.insert(address)
        return true
    }

    /// Next address to start, if a slot is free.
    mutating func next() -> String? {
        guard inFlight.count < maxConcurrent, !pending.isEmpty else { return nil }
        let a = pending.removeFirst()
        pendingSet.remove(a)
        inFlight.insert(a)
        return a
    }

    mutating func finish(_ address: String) {
        inFlight.remove(address)
    }
}

/// FFI: `getnameinfo` on an IP literal.
enum ReverseDNSLookup {
    /// Raw sockaddr bytes for an IPv4/IPv6 literal (port 0); nil if it isn't one.
    static func sockaddrBytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_addr = v4
            return withUnsafeBytes(of: &sin) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_addr = v6
            return withUnsafeBytes(of: &sin6) { Array($0) }
        }
        return nil
    }

    /// Blocking PTR lookup (runs on the ReverseDNS queue only). nil when there is no name.
    @Sendable static func hostName(_ address: String) -> String? {
        guard let sa = sockaddrBytes(address), sa.count <= MemoryLayout<sockaddr_storage>.size else { return nil }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { dst in
            for (i, b) in sa.enumerated() { dst[i] = b }
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &storage) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                host.withUnsafeMutableBufferPointer { h in
                    getnameinfo(sp, socklen_t(sa.count), h.baseAddress, socklen_t(h.count), nil, 0, NI_NAMEREQD)
                }
            }
        }
        guard rc == 0 else { return nil }
        let name = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return name.isEmpty || name == address ? nil : name
    }
}
