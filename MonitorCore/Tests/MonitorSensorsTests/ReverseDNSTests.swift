import Darwin
import Foundation
import os
import Testing
@testable import MonitorSensors

@Suite struct ReverseDNSTests {
    @Test func cacheHitMissAndTTL() {
        var c = ReverseDNSCache(capacity: 4, ttlNs: 100)
        #expect(c.lookup("1.1.1.1", nowNs: 0) == .miss)
        c.store("1.1.1.1", name: "one.one.one.one", nowNs: 10)
        c.store("10.0.0.9", name: nil, nowNs: 10) // negative result cached too
        #expect(c.lookup("1.1.1.1", nowNs: 50) == .hit("one.one.one.one"))
        #expect(c.lookup("10.0.0.9", nowNs: 50) == .hit(nil))
        #expect(c.lookup("1.1.1.1", nowNs: 110) == .miss) // expired and dropped
        #expect(c.count == 1)
    }

    @Test func evictsLeastRecentlyUsed() {
        var c = ReverseDNSCache(capacity: 3, ttlNs: 1_000)
        c.store("a", name: "A", nowNs: 0)
        c.store("b", name: "B", nowNs: 0)
        c.store("c", name: "C", nowNs: 0)
        _ = c.lookup("a", nowNs: 1) // a is now most recent; b is LRU
        c.store("d", name: "D", nowNs: 2)
        #expect(c.count == 3)
        #expect(c.lookup("b", nowNs: 3) == .miss)
        #expect(c.lookup("a", nowNs: 3) == .hit("A"))
        #expect(c.lookup("d", nowNs: 3) == .hit("D"))
    }

    @Test func jobsDedupeAndLimit() {
        var j = ReverseDNSJobs(maxConcurrent: 2, maxPending: 3)
        let queued = ["a", "a", "b", "c", "d"].map { j.request($0) }
        #expect(queued == [true, false, true, true, false]) // dedupe; queue full at 3
        let started = [j.next(), j.next(), j.next()]
        #expect(started == ["a", "b", nil]) // 2 in flight
        let requeued = j.request("a")
        #expect(!requeued) // in flight
        j.finish("a")
        let third = j.next()
        #expect(third == "c")
        #expect(j.pending.isEmpty)
    }

    @Test func sockaddrBytesRoundTrip() {
        let v4 = ReverseDNSLookup.sockaddrBytes("192.168.1.1")
        #expect(v4?.count == 16)
        #expect(v4.flatMap(NetSockaddr.decode) == NetEndpoint(address: "192.168.1.1", port: 0))
        let v6 = ReverseDNSLookup.sockaddrBytes("2606:4700::1111")
        #expect(v6?.count == 28)
        #expect(v6.flatMap(NetSockaddr.decode)?.address == "2606:4700::1111")
        #expect(ReverseDNSLookup.sockaddrBytes("example.com") == nil)
        #expect(ReverseDNSLookup.sockaddrBytes("") == nil)
    }

    /// Fake resolver that blocks until released, counting peak concurrency.
    final class Gate: Sendable {
        let release = DispatchSemaphore(value: 0)
        let stats = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0, calls: 0))
        func resolve(_ a: String) -> String? {
            stats.withLock { s in
                s.current += 1
                s.calls += 1
                s.peak = max(s.peak, s.current)
            }
            release.wait()
            stats.withLock { $0.current -= 1 }
            return "host-\(a)"
        }
    }

    static func waitUntil(_ cond: () -> Bool) {
        for _ in 0..<200 where !cond() { usleep(5_000) }
    }

    @Test func nameNeverBlocksAndRespectsConcurrency() {
        let gate = Gate()
        let dns = ReverseDNS(maxConcurrent: 4, resolve: { gate.resolve($0) }, now: { 0 })
        let t0 = W6cClock.uptimeNs()
        for i in 0..<10 { #expect(dns.name(for: "10.0.0.\(i)") == nil) }
        #expect(W6cClock.uptimeNs() - t0 < 50_000_000) // resolvers are blocked; name() is not
        Self.waitUntil { dns.inFlightCount == 4 }
        #expect(dns.inFlightCount == 4)
        for _ in 0..<10 { gate.release.signal() }
        Self.waitUntil { dns.cacheCount == 10 }
        #expect(gate.stats.withLock { $0.peak } <= 4)
        #expect(gate.stats.withLock { $0.calls } == 10)
        #expect(dns.name(for: "10.0.0.3") == "host-10.0.0.3")
        #expect(dns.names(for: ["10.0.0.1", "10.0.0.2", "9.9.9.9"]) == ["10.0.0.1": "host-10.0.0.1", "10.0.0.2": "host-10.0.0.2"])
        gate.release.signal() // for the 9.9.9.9 lookup just scheduled
    }

    @Test func expiredEntriesAreLookedUpAgain() {
        let clock = OSAllocatedUnfairLock(initialState: UInt64(0))
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let dns = ReverseDNS(ttlNs: 1_000, resolve: { a in calls.withLock { $0 += 1 }; return "n-\(a)" },
                             now: { clock.withLock { $0 } })
        _ = dns.name(for: "1.2.3.4")
        Self.waitUntil { dns.name(for: "1.2.3.4") != nil }
        #expect(calls.withLock { $0 } == 1)
        _ = dns.name(for: "1.2.3.4") // cached
        #expect(calls.withLock { $0 } == 1)
        clock.withLock { $0 = 5_000 }
        #expect(dns.name(for: "1.2.3.4") == nil) // expired → re-queued
        Self.waitUntil { calls.withLock { $0 } == 2 }
        #expect(calls.withLock { $0 } == 2)
    }
}

/// `TELLTALE_HW_TESTS=1 scripts/test.sh ReverseDNSSmokeTests`.
@Suite(.enabled(if: W6cFixture.hardwareTests))
struct ReverseDNSSmokeTests {
    @Test func resolvesLoopbackAsync() {
        let dns = ReverseDNS()
        #expect(dns.name(for: "127.0.0.1") == nil)
        var name: String?
        for _ in 0..<200 where name == nil {
            usleep(10_000)
            name = dns.name(for: "127.0.0.1")
        }
        let direct = ReverseDNSLookup.hostName("127.0.0.1")
        print("W6c rdns: 127.0.0.1 → \(name ?? "nil") (direct \(direct ?? "nil"))")
        #expect(name == "localhost")
        #expect(name == direct)
    }
}
