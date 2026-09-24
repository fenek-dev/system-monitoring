import Foundation

/// Pure SMC value decoding (docs/findings/smc.md). Byte order depends on the key family:
/// - `flt ` (Float32): little-endian, always.
/// - integers of battery/charger keys (`B<digit>…`, `CH…`): LITTLE-endian (verified vs ioreg: B0CT, B0DC, CHBV).
/// - all other integers and fixed-point (`sp78`, `fpe2`, fan/temp families): big-endian.
enum SMCDecoder {
    enum ByteOrder: Sendable, Equatable { case big, little }

    /// Big-endian FourCC → String ("flt ", "ui16"); "" for 0.
    static func fourCC(_ v: UInt32) -> String {
        guard v != 0 else { return "" }
        return String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) }, as: UTF8.self)
    }

    static func integerByteOrder(forKey key: String) -> ByteOrder {
        let k = Array(key.utf8)
        guard k.count >= 2 else { return .big }
        if k[0] == UInt8(ascii: "B"), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(k[1]) { return .little }
        if k[0] == UInt8(ascii: "C"), k[1] == UInt8(ascii: "H") { return .little }
        return .big
    }

    /// Unsigned integer of the first `n` bytes in `order`; nil if too short.
    static func unsigned(_ bytes: [UInt8], _ n: Int, _ order: ByteOrder) -> UInt64? {
        guard n > 0, n <= 8, bytes.count >= n else { return nil }
        let slice = order == .big ? Array(bytes[0..<n]) : bytes[0..<n].reversed()
        return slice.reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func signed(_ bytes: [UInt8], _ n: Int, _ order: ByteOrder) -> Int64? {
        guard let u = unsigned(bytes, n, order) else { return nil }
        let shift = UInt64(64 - n * 8)
        return Int64(bitPattern: u << shift) >> Int64(shift)      // sign-extend
    }

    /// Numeric value, or nil for unknown/non-numeric types, short buffers and non-finite floats.
    static func decode(key: String, type: String, bytes: [UInt8]) -> Double? {
        let order = integerByteOrder(forKey: key)
        let v: Double?
        switch type {
        case "flt ":
            v = unsigned(bytes, 4, .little).map { Double(Float(bitPattern: UInt32(truncatingIfNeeded: $0))) }
        // `{ Double($0) }`, never a bare Double-init map: on UInt64 that resolves to Double(bitPattern:).
        case "ui8 ", "flag": v = unsigned(bytes, 1, order).map { Double($0) }
        case "ui16": v = unsigned(bytes, 2, order).map { Double($0) }
        case "ui32": v = unsigned(bytes, 4, order).map { Double($0) }
        case "ui64": v = unsigned(bytes, 8, order).map { Double($0) }
        case "si8 ": v = signed(bytes, 1, order).map { Double($0) }
        case "si16": v = signed(bytes, 2, order).map { Double($0) }
        case "si32": v = signed(bytes, 4, order).map { Double($0) }
        case "si64": v = signed(bytes, 8, order).map { Double($0) }
        case "sp78": v = signed(bytes, 2, order).map { Double($0) / 256 }
        case "fpe2": v = unsigned(bytes, 2, order).map { Double($0) / 4 }
        case "fp88": v = unsigned(bytes, 2, order).map { Double($0) / 256 }
        default: v = nil
        }
        guard let v, v.isFinite else { return nil }
        return v
    }

    /// Filter for T-keys in the raw list (findings: 5 < °C < 130).
    static func isPlausibleTemperature(_ c: Double) -> Bool { c.isFinite && c > 5 && c < 130 }
}
