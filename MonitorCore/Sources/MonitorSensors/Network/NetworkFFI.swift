import Darwin
import MonitorModel
import SystemConfiguration

/// W6c FFI: routing-socket sysctls and SystemConfiguration lookups. Parsing lives in RouteParse / InterfaceParse.
enum NetworkFFI {
    /// Reads a sysctl into `buffer` (reused across calls; grown on ENOMEM). Returns the valid byte count.
    static func sysctlDump(_ mib: [Int32], into buffer: inout [UInt8], context: String) throws(SensorError) -> Int {
        var mib = mib
        for _ in 0..<4 {
            var len = 0
            guard sysctl(&mib, u_int(mib.count), nil, &len, nil, 0) == 0 else { throw SensorError.fromErrno(context) }
            if len == 0 { return 0 }
            if buffer.count < len + len / 8 { buffer = [UInt8](repeating: 0, count: len + len / 4) }
            len = buffer.count
            let rc = buffer.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &len, nil, 0) }
            if rc == 0 { return len }
            if errno != ENOMEM { throw SensorError.fromErrno(context) }
        }
        throw .transient("\(context): table kept growing")
    }

    /// `NET_RT_IFLIST2`: every interface with 64-bit counters.
    static func interfaces(_ buffer: inout [UInt8]) throws(SensorError) -> [RawInterface] {
        let n = try sysctlDump([CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0], into: &buffer, context: "sysctl NET_RT_IFLIST2")
        return buffer.withUnsafeBytes { InterfaceParse.interfaces(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
    }

    /// Raw `struct ifmibdata` bytes for one interface index (64-bit counters).
    static func ifmibBytes(index: UInt16) -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFDATA, Int32(index), IFDATA_GENERAL]
        var bytes = [UInt8](repeating: 0, count: MemoryLayout<ifmibdata>.size)
        var len = bytes.count
        let rc = bytes.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &len, nil, 0) }
        guard rc == 0, len == bytes.count else { return nil }
        return bytes
    }

    /// IFMIB 64-bit counters for each row's index (missing on failure).
    static func ifmibCounters(_ rows: [RawInterface]) -> [UInt16: IFCounters] {
        var out: [UInt16: IFCounters] = [:]
        for r in rows {
            if let b = ifmibBytes(index: r.index), let c = b.withUnsafeBytes({ InterfaceParse.ifmib($0) }) { out[r.index] = c }
        }
        return out
    }

    /// `NET_RT_FLAGS` + `RTF_GATEWAY`, IPv4 only.
    static func defaultRoutes() throws(SensorError) -> [DefaultRoute] {
        var buffer: [UInt8] = []
        let n = try sysctlDump([CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY], into: &buffer,
                               context: "sysctl NET_RT_FLAGS")
        return buffer.withUnsafeBytes { RouteParse.defaultGateways(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
    }

    /// `State:/Network/Global/IPv4`: primary interface and SC's router.
    static func globalIPv4(_ store: SCDynamicStore?) -> (primary: String?, router: String?) {
        guard let store, let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return (nil, nil) }
        return (v["PrimaryInterface"] as? String, v["Router"] as? String)
    }

    /// Router of the primary interface: the default route on it (VPN / several defaults), else the first default
    /// route, else SystemConfiguration's Router.
    static func router(primary: String?, scRouter: String?) -> String? {
        let routes = (try? defaultRoutes()) ?? []
        let index = primary.map { if_nametoindex($0) }.flatMap { $0 == 0 ? nil : UInt16(truncatingIfNeeded: $0) }
        return RouteParse.pick(routes, primaryIndex: index)?.gateway ?? scRouter
    }

    /// Latency target: router of the physical primary interface (`RouteParse.physicalRouter`).
    static func physicalRouter(_ store: SCDynamicStore?) -> RouterChoice {
        let g = globalIPv4(store)
        let routes = (try? defaultRoutes()) ?? []
        var names: [UInt16: String] = [:]
        for r in routes where names[r.interfaceIndex] == nil {
            var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
            let n = buf.withUnsafeMutableBufferPointer { b -> String? in
                guard let base = b.baseAddress, if_indextoname(UInt32(r.interfaceIndex), base) != nil else { return nil }
                return String(cString: base)
            }
            if let n { names[r.interfaceIndex] = n }
        }
        return RouteParse.physicalRouter(routes, names: names, primary: g.primary, scRouter: g.router)
    }

    /// Hardware interfaces SystemConfiguration knows (bsd name → type, localized name).
    static func descriptors() -> [String: InterfaceDescriptor] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var out: [String: InterfaceDescriptor] = [:]
        for i in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(i) as String? ?? ""
            let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? ?? bsd
            out[bsd] = InterfaceDescriptor(bsdName: bsd, displayName: name, type: type)
        }
        return out
    }

    static func makeStore(_ name: String) -> SCDynamicStore? {
        SCDynamicStoreCreate(nil, name as CFString, nil, nil)
    }
}
