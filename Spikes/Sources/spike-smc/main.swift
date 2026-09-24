import Foundation
import CPrivate

let conn = smc_open()
guard conn != 0 else { print("smc_open failed"); exit(1) }
defer { smc_close(conn) }

func fourccString(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

func read(_ key: String) -> (type: String, bytes: [UInt8])? {
    var type: UInt32 = 0, size: UInt32 = 0
    var buf = [UInt8](repeating: 0, count: 32)
    guard smc_read(conn, key, &type, &buf, &size) == 0 else { return nil }
    return (fourccString(type), Array(buf.prefix(Int(size))))
}

// Apple Silicon: 'flt ' is little-endian Float32; integer types are big-endian.
func value(_ r: (type: String, bytes: [UInt8])) -> Double? {
    let b = r.bytes
    switch r.type {
    case "flt " where b.count >= 4: return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
    case "ui8 " where b.count >= 1: return Double(b[0])
    case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
    case "ui32" where b.count >= 4: return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
    default: return nil
    }
}

let fanCount = read("FNum").flatMap(value).map(Int.init) ?? 0
print("fans=\(fanCount)")
for i in 0..<fanCount {
    let parts = ["Ac", "Mn", "Mx", "Tg"].map { s -> String in
        let r = read("F\(i)\(s)")
        return "\(s)=\(r.flatMap(value).map { String(format: "%.0f", $0) } ?? "–")(\(r?.type ?? "?"))"
    }
    print("  F\(i): " + parts.joined(separator: " "))
}

let keyCount = read("#KEY").flatMap(value).map(Int.init) ?? 0
var temps: [(String, Double)] = []
let clock = ContinuousClock()
let enumCost = clock.measure {
    var k = [CChar](repeating: 0, count: 5)
    for idx in 0..<keyCount {
        guard smc_key_at(conn, UInt32(idx), &k) == 0 else { continue }
        let key = String(cString: k)
        guard key.hasPrefix("T"), let r = read(key), r.type == "flt ", let v = value(r), v > 5, v < 130 else { continue }
        temps.append((key, v))
    }
}
print("keys=\(keyCount) plausibleTempKeys=\(temps.count) enumCost=\(enumCost)")
print(temps.prefix(60).map { "\($0.0)=\(String(format: "%.1f", $0.1))" }.joined(separator: " "))

// EXTRA: battery / power keys for the Power/Battery screen.
print("\n-- battery/power keys --")
let batteryKeys = [
    "B0CT",  // cycle count
    "B0FC",  // full capacity
    "B0DC",  // design capacity
    "B0TE",  // time to empty
    "B0TF",  // time to full
    "PSTR",  // system total power
    "PDTR",  // ? power delivered/DC-in related
    "B0AC",  // amperage
    "B0AV",  // voltage
    "CHBV",  // charger board voltage
    "CHLC",  // charger limit current
]
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

// Decode assuming both byte orders so we can tell which one a given SMC key actually uses.
func beU(_ b: [UInt8]) -> UInt64 { b.reduce(0) { ($0 << 8) | UInt64($1) } }
func leU(_ b: [UInt8]) -> UInt64 { b.reversed().reduce(0) { ($0 << 8) | UInt64($1) } }
func asSigned(_ u: UInt64, bits: Int) -> Int64 {
    let signBit: UInt64 = 1 << (bits - 1)
    return (u & signBit) != 0 ? Int64(u) - (1 << bits) : Int64(u)
}

for key in batteryKeys {
    if let r = read(key) {
        let v = value(r)
        let vStr = v.map { String(format: "%.3f", $0) } ?? "n/a"
        var alt = ""
        if r.type.hasPrefix("ui") || r.type.hasPrefix("si") {
            let be = beU(r.bytes), le = leU(r.bytes)
            let bits = r.bytes.count * 8
            if r.type.hasPrefix("si") {
                alt = " beSigned=\(asSigned(be, bits: bits)) leSigned=\(asSigned(le, bits: bits))"
            } else {
                alt = " be=\(be) le=\(le)"
            }
        }
        print("  \(key): type=\(r.type) bytes=\(r.bytes.count) hex=\(hex(r.bytes)) value=\(vStr)\(alt)")
    } else {
        print("  \(key): absent")
    }
}
