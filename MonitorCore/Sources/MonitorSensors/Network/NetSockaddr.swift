import Darwin

/// A decoded socket address. `address == nil` for the wildcard (0.0.0.0 / ::).
struct NetEndpoint: Sendable, Equatable {
    var address: String?
    var port: UInt16
}

/// Pure decoding of raw `sockaddr` bytes (as NStat's `localAddress`/`remoteAddress` CFData, or routing messages).
/// Layout: `sa_len` at 0, `sa_family` at 1, port (big-endian) at 2; IPv4 address at 4, IPv6 address at 8.
enum NetSockaddr {
    static func decode(_ bytes: [UInt8]) -> NetEndpoint? {
        bytes.withUnsafeBytes { decode($0) }
    }

    static func decode(_ raw: UnsafeRawBufferPointer) -> NetEndpoint? {
        guard raw.count >= 2 else { return nil }
        let saLen = Int(raw[0])
        // sa_len must not claim more than we hold (0 = unset: trust the buffer).
        guard saLen <= raw.count else { return nil }
        let port = raw.count >= 4 ? UInt16(raw[2]) << 8 | UInt16(raw[3]) : 0
        switch Int32(raw[1]) {
        case AF_INET:
            guard raw.count >= 8 else { return nil }
            let a = (raw[4], raw[5], raw[6], raw[7])
            if a == (0, 0, 0, 0) { return NetEndpoint(address: nil, port: port) }
            return NetEndpoint(address: "\(a.0).\(a.1).\(a.2).\(a.3)", port: port)
        case AF_INET6:
            guard raw.count >= 24 else { return nil }
            var bytes = [UInt8](repeating: 0, count: 16)
            for i in 0..<16 { bytes[i] = raw[8 + i] }
            if bytes.allSatisfy({ $0 == 0 }) { return NetEndpoint(address: nil, port: port) }
            // IPv4-mapped (::ffff:a.b.c.d) → plain IPv4 text.
            if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                return NetEndpoint(address: "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])", port: port)
            }
            return NetEndpoint(address: ipv6Text(bytes), port: port)
        default:
            return nil
        }
    }

    /// `inet_ntop` for a 16-byte IPv6 address.
    static func ipv6Text(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { dst in
            for i in 0..<16 { dst[i] = bytes[i] }
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return buf.withUnsafeMutableBufferPointer { b -> String? in
            guard let base = b.baseAddress, inet_ntop(AF_INET6, &addr, base, socklen_t(b.count)) != nil else { return nil }
            return String(cString: base)
        }
    }
}
