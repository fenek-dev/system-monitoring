import Darwin

/// One routing-socket message's address slots and header fields.
struct RouteEntry: Sendable, Equatable {
    var destination: NetEndpoint?
    var destinationFamily: Int32
    var gateway: String?
    var interfaceIndex: UInt16
    var flags: Int32
}

enum RouterChoice: Sendable, Equatable {
    case router(String)
    case vpnOnly
    case noRoute
}

/// A default route (destination 0.0.0.0 via an IPv4 gateway).
struct DefaultRoute: Sendable, Equatable {
    var gateway: String
    var interfaceIndex: UInt16
}

/// Pure parsing of `sysctl(CTL_NET, PF_ROUTE, …)` dumps (`NET_RT_FLAGS`, `NET_RT_IFLIST2`).
///
/// XNU pads every sockaddr after a routing header to a 4-byte boundary (`ROUNDUP32` in rtsock.c), not
/// `sizeof(long)`; an `sa_len` of 0 still occupies 4 bytes (docs/findings/extras.md §4).
enum RouteParse {
    static func roundUp32(_ len: Int) -> Int {
        len <= 0 ? 4 : (len + 3) & ~3
    }

    /// Byte ranges of the sockaddrs present in `addrs` (bitmask of `RTAX_*`), starting at `start`, bounded by `end`.
    static func sockaddrSlots(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int, addrs: Int32) -> [Int: Range<Int>] {
        var slots: [Int: Range<Int>] = [:]
        var offset = start
        for i in 0..<Int(RTAX_MAX) where addrs & (Int32(1) << Int32(i)) != 0 {
            guard offset < end else { break }
            let saLen = Int(raw[offset])
            let len = min(max(saLen, 0), end - offset)
            slots[i] = offset..<(offset + len)
            offset += roundUp32(saLen)
        }
        return slots
    }

    /// Every message of a `NET_RT_FLAGS`/`NET_RT_DUMP` dump.
    static func routes(_ raw: UnsafeRawBufferPointer) -> [RouteEntry] {
        let header = MemoryLayout<rt_msghdr>.size
        var out: [RouteEntry] = []
        var offset = 0
        while offset + header <= raw.count {
            let rtm = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
            let msgLen = Int(rtm.rtm_msglen)
            guard msgLen >= header, offset + msgLen <= raw.count else { break }
            let end = offset + msgLen
            let slots = sockaddrSlots(raw, from: offset + header, to: end, addrs: rtm.rtm_addrs)
            var e = RouteEntry(destination: nil, destinationFamily: AF_UNSPEC, gateway: nil,
                               interfaceIndex: rtm.rtm_index, flags: rtm.rtm_flags)
            if let r = slots[Int(RTAX_DST)], r.count >= 2 {
                e.destinationFamily = Int32(raw[r.lowerBound + 1])
                e.destination = NetSockaddr.decode(UnsafeRawBufferPointer(rebasing: raw[r]))
            }
            if let r = slots[Int(RTAX_GATEWAY)], r.count >= 2, Int32(raw[r.lowerBound + 1]) == AF_INET {
                e.gateway = NetSockaddr.decode(UnsafeRawBufferPointer(rebasing: raw[r]))?.address
            }
            out.append(e)
            offset = end
        }
        return out
    }

    /// Default IPv4 routes with an IP gateway, in dump order.
    static func defaultGateways(_ raw: UnsafeRawBufferPointer) -> [DefaultRoute] {
        routes(raw).compactMap { e in
            guard e.destinationFamily == AF_INET, e.destination?.address == nil, let gw = e.gateway else { return nil }
            return DefaultRoute(gateway: gw, interfaceIndex: e.interfaceIndex)
        }
    }

    /// Physical (non-tunnel) interfaces are Ethernet-class `en*` (Wi-Fi, Ethernet, Thunderbolt, USB).
    static func isPhysical(_ name: String?) -> Bool { name?.hasPrefix("en") ?? false }

    /// Latency target (ruling 2026-09-24): the router of the **physical** primary interface, never a VPN gateway.
    /// Primary physical → its default route (else SystemConfiguration's router, else the first physical route).
    /// Primary a tunnel (utun/ipsec/ppp) or unknown → the first physical default route (scoped routes stay in the
    /// dump). Only tunnel routes → `.vpnOnly`; none at all → `.noRoute`.
    static func physicalRouter(_ routes: [DefaultRoute], names: [UInt16: String], primary: String?,
                               scRouter: String?) -> RouterChoice {
        let physical = routes.filter { isPhysical(names[$0.interfaceIndex]) }
        if isPhysical(primary) {
            if let r = physical.first(where: { names[$0.interfaceIndex] == primary }) { return .router(r.gateway) }
            if let sc = scRouter { return .router(sc) }
        }
        if let r = physical.first { return .router(r.gateway) }
        if !routes.isEmpty || (primary != nil && !isPhysical(primary)) { return .vpnOnly }
        return .noRoute
    }

    /// Several default routes (VPN, scoped routes): prefer the primary interface's, else the first.
    static func pick(_ routes: [DefaultRoute], primaryIndex: UInt16?) -> DefaultRoute? {
        if let p = primaryIndex, let r = routes.first(where: { $0.interfaceIndex == p }) { return r }
        return routes.first
    }
}
