import Darwin
import MonitorModel

/// One interface from a `NET_RT_IFLIST2` dump: 64-bit counters (`if_data64`) + first IPv4 address.
struct RawInterface: Sendable, Equatable {
    var index: UInt16
    var name: String
    var flags: Int32
    var rxBytes: UInt64
    var txBytes: UInt64
    var baudRate: UInt64
    var ipv4: String?

    var isUp: Bool { flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 }
    var isLoopback: Bool { flags & IFF_LOOPBACK != 0 }
}

/// What SystemConfiguration says about an interface (FFI side fills it).
struct InterfaceDescriptor: Sendable, Equatable {
    var bsdName: String
    var displayName: String
    /// `kSCNetworkInterfaceType*` value, e.g. "IEEE80211", "Ethernet", "Bridge", "WWAN".
    var type: String
}

enum InterfaceParse {
    /// Parses `sysctl {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0}`: `RTM_IFINFO2` messages (header `if_msghdr2`
    /// + `sockaddr_dl` name) followed by `RTM_NEWADDR` messages (`ifa_msghdr` + sockaddrs, ROUNDUP32-padded).
    static func interfaces(_ raw: UnsafeRawBufferPointer) -> [RawInterface] {
        var out: [RawInterface] = []
        var byIndex: [UInt16: Int] = [:]
        var offset = 0
        // Common prefix of every routing message: u_short msglen, u_char version, u_char type.
        while offset + 4 <= raw.count {
            let msgLen = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            let type = Int32(raw[offset + 3])
            guard msgLen >= 4, offset + msgLen <= raw.count else { break }
            let end = offset + msgLen
            defer { offset = end }
            switch type {
            case RTM_IFINFO2:
                let size = MemoryLayout<if_msghdr2>.size
                guard msgLen >= size else { continue }
                let h = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                let slots = RouteParse.sockaddrSlots(raw, from: offset + size, to: end, addrs: h.ifm_addrs)
                let name = slots[Int(RTAX_IFP)].flatMap { linkName(UnsafeRawBufferPointer(rebasing: raw[$0])) }
                    ?? "if\(h.ifm_index)"
                byIndex[h.ifm_index] = out.count
                out.append(RawInterface(index: h.ifm_index, name: name, flags: h.ifm_flags,
                                        rxBytes: h.ifm_data.ifi_ibytes, txBytes: h.ifm_data.ifi_obytes,
                                        baudRate: h.ifm_data.ifi_baudrate))
            case RTM_NEWADDR:
                let size = MemoryLayout<ifa_msghdr>.size
                guard msgLen >= size else { continue }
                let h = raw.loadUnaligned(fromByteOffset: offset, as: ifa_msghdr.self)
                guard let i = byIndex[h.ifam_index], out[i].ipv4 == nil else { continue }
                let slots = RouteParse.sockaddrSlots(raw, from: offset + size, to: end, addrs: h.ifam_addrs)
                guard let r = slots[Int(RTAX_IFA)], r.count >= 8, Int32(raw[r.lowerBound + 1]) == AF_INET else { continue }
                out[i].ipv4 = NetSockaddr.decode(UnsafeRawBufferPointer(rebasing: raw[r]))?.address
            default:
                continue
            }
        }
        return out
    }

    /// Name from a `sockaddr_dl` (`sdl_nlen` at 5, `sdl_data` at 8).
    static func linkName(_ sdl: UnsafeRawBufferPointer) -> String? {
        guard sdl.count >= 8, Int32(sdl[1]) == AF_LINK else { return nil }
        let nlen = Int(sdl[5])
        guard nlen > 0, 8 + nlen <= sdl.count else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: sdl[8..<(8 + nlen)]), as: UTF8.self)
    }

    static func kind(_ d: InterfaceDescriptor?) -> InterfaceKind {
        if let d {
            let label = d.displayName.lowercased()
            switch d.type {
            case "IEEE80211": return .wifi
            case "WWAN", "PPP": return .cellular
            case "Ethernet", "Bridge":
                if label.contains("thunderbolt") { return .thunderbolt }
                if label.contains("iphone") || label.contains("ipad") { return .cellular }
                return d.type == "Ethernet" ? .ethernet : .other
            default: return .other
            }
        }
        return .other
    }

    /// 64-bit counters from `sysctl {CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, index, IFDATA_GENERAL}`
    /// (`struct ifmibdata`). Needed because `NET_RT_IFLIST2` (and getifaddrs) truncate byte counters to 32 bits
    /// for unprivileged callers on macOS 26 (packet counters stay 64-bit).
    static func ifmib(_ raw: UnsafeRawBufferPointer) -> (rx: UInt64, tx: UInt64, baudRate: UInt64)? {
        guard raw.count >= MemoryLayout<ifmibdata>.size else { return nil }
        let d = raw.loadUnaligned(as: ifmibdata.self).ifmd_data
        return (d.ifi_ibytes, d.ifi_obytes, d.ifi_baudrate)
    }

    /// Interfaces the reading reports: hardware SystemConfiguration knows, plus the primary one; never loopback.
    static func included(_ raw: [RawInterface], descriptors: [String: InterfaceDescriptor], primary: String?) -> [RawInterface] {
        raw.filter { !$0.isLoopback && (descriptors[$0.name] != nil || $0.name == primary) }
    }

    /// Reading rows for `included` interfaces (callers pass `raw` already overlaid with 64-bit counters).
    static func reading(_ raw: [RawInterface], descriptors: [String: InterfaceDescriptor], primary: String?,
                        router: String?) -> InterfacesReading {
        let rows = included(raw, descriptors: descriptors, primary: primary).map { r -> InterfaceCounter in
            let d = descriptors[r.name]
            return InterfaceCounter(bsdName: r.name, displayName: d?.displayName ?? r.name, kind: kind(d),
                                    isUp: r.isUp, isPrimary: r.name == primary, rxBytes: r.rxBytes, txBytes: r.txBytes,
                                    ipv4: r.ipv4, linkRateBps: r.baudRate > 0 ? Double(r.baudRate) : nil)
        }
        return InterfacesReading(interfaces: rows, routerIPv4: router)
    }
}
