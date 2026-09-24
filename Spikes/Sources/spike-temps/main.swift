import Foundation
import IOKit.hidsystem
import CPrivate

// MARK: - SMC helpers (Fix round 1: CPU-P/CPU-E/GPU split via SMC, HID names
// carry no such tag on this machine — see docs/findings/temps.md).
// Duplicated from spike-smc's decode logic (separate executable target, no
// shared library between spikes) — see docs/findings/smc.md for the shim
// contract (smc_open/smc_read/smc_key_at) and the endianness caveats.

func fourccString(_ v: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
}

/// Reads any of the numeric SMC types spike-smc encountered (flt/ui8/ui16/ui32).
func smcReadNumber(_ conn: io_connect_t, _ key: String) -> (type: String, value: Double)? {
    var type: UInt32 = 0, size: UInt32 = 0
    var buf = [UInt8](repeating: 0, count: 32)
    guard smc_read(conn, key, &type, &buf, &size) == 0 else { return nil }
    let t = fourccString(type)
    switch t {
    case "flt " where size >= 4:
        let bits = UInt32(buf[0]) | UInt32(buf[1]) << 8 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 24
        return (t, Double(Float(bitPattern: bits)))
    case "ui8 " where size >= 1: return (t, Double(buf[0]))
    case "ui16" where size >= 2: return (t, Double(UInt16(buf[0]) << 8 | UInt16(buf[1])))
    case "ui32" where size >= 4: return (t, Double(UInt32(buf[0]) << 24 | UInt32(buf[1]) << 16 | UInt32(buf[2]) << 8 | UInt32(buf[3])))
    default: return nil
    }
}

/// Every plausible temperature key: T-prefixed, `flt `, 5 < v < 130 — same
/// filter spike-smc used to find 217 keys (docs/findings/smc.md). Returns
/// (key, value) pairs, unsorted, in SMC key-index order.
func smcAllTempKeys(_ conn: io_connect_t) -> [(String, Double)] {
    guard let keyCount = smcReadNumber(conn, "#KEY")?.value else { return [] }
    var out: [(String, Double)] = []
    var k = [CChar](repeating: 0, count: 5)
    for idx in 0..<Int(keyCount) {
        guard smc_key_at(conn, UInt32(idx), &k) == 0 else { continue }
        let key = String(cString: k)
        guard key.hasPrefix("T"), let r = smcReadNumber(conn, key), r.type == "flt ", r.value > 5, r.value < 130 else { continue }
        out.append((key, r.value))
    }
    return out
}

/// Fix round 1: minimal standalone HID read, used only to cross-check the
/// SMC-derived SSD/Battery readings in `--curated` mode (see
/// docs/findings/temps.md "SMC cross-check" -- NAND vs SMC Td disagrees by
/// ~13-15C; battery agrees within noise).
func hidCrossCheck() -> (nand: Double?, battery: Double?) {
    let hidType = Int64(kSMHIDEventTypeTemperature)
    let hidField = Int32(hidType << 16)
    guard let hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return (nil, nil) }
    let hidMatching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
    _ = IOHIDEventSystemClientSetMatching(hidClient, hidMatching)
    let hidServices = (IOHIDEventSystemClientCopyServices(hidClient) as? [IOHIDServiceClient]) ?? []
    var nand: [Double] = [], battery: [Double] = []
    for svc in hidServices {
        let name = IOHIDServiceClientCopyProperty(svc, "Product" as CFString) as? String ?? "?"
        guard let ev = IOHIDServiceClientCopyEvent(svc, hidType, 0, 0) else { continue }
        let v = IOHIDEventGetFloatValue(ev, hidField)
        if name.hasPrefix("NAND") { nand.append(v) }
        if name.contains("gas gauge battery") { battery.append(v) }
    }
    func avg(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
    return (avg(nand), avg(battery))
}

/// Fix round 1, step 2: `--delta` snapshot mode. Prints every plausible T-key
/// on its own line for scripted baseline/under-load diffing (see
/// docs/findings/temps.md for the 3 targeted-load experiments this feeds).
if CommandLine.arguments.contains("--delta") {
    let conn = smc_open()
    guard conn != 0 else { print("smc_open failed"); exit(1) }
    defer { smc_close(conn) }
    let clock = ContinuousClock()
    var keys: [(String, Double)] = []
    let cost = clock.measure { keys = smcAllTempKeys(conn) }
    print("smc-delta: n=\(keys.count) cost=\(cost)")
    for (k, v) in keys.sorted(by: { $0.0 < $1.0 }) {
        print("\(k) \(String(format: "%.2f", v))")
    }
    exit(0)
}

// MARK: - Fix round 1, step 4: perf mitigation — curated SMC key set (direct
// reads by exact name, no full-keyspace enumeration) vs full SMC enumeration
// vs the HID full read, plus a cross-check of the SMC-derived CPU-die average
// against HID's SoC/PMU bucket average. Mapping is hardcoded from the 3
// targeted-load delta experiments in docs/findings/temps.md.
if CommandLine.arguments.contains("--curated") {
    let conn = smc_open()
    guard conn != 0 else { print("smc_open failed"); exit(1) }
    defer { smc_close(conn) }
    let clock = ContinuousClock()

    // Full-enumeration cost, for comparison (same as smc.md: ~0.45-0.57s over 2121 keys).
    var fullKeys: [(String, Double)] = []
    let fullEnumCost = clock.measure { fullKeys = smcAllTempKeys(conn) }
    print("smc full enumeration: n=\(fullKeys.count) cost=\(fullEnumCost)")

    // Curated fast read: exact key names only, no enumeration at all.
    // See docs/findings/temps.md "Final mapping" for how each family was
    // classified (P vs E vs GPU vs SoC vs SSD vs battery) via under-load delta.
    let curatedKeys: [String: [String]] = [
        "CPU P-cores": SMCCuratedKeys.cpuP,
        "CPU E-cores": SMCCuratedKeys.cpuE,
        "GPU": SMCCuratedKeys.gpu,
        "SoC": SMCCuratedKeys.soc,
        "SSD": SMCCuratedKeys.ssd,
        "Battery": SMCCuratedKeys.battery,
        "Ambient": SMCCuratedKeys.ambient,
    ]
    var curatedValues: [String: [Double]] = [:]
    let curatedReadCost = clock.measure {
        for (group, keys) in curatedKeys {
            curatedValues[group] = keys.compactMap { smcReadNumber(conn, $0)?.value }
        }
    }
    let totalCuratedKeys = curatedKeys.values.reduce(0) { $0 + $1.count }
    print("smc curated read: n=\(totalCuratedKeys) cost=\(curatedReadCost)")
    print("\n--- curated groups (SMC, direct read) ---")
    for group in ["CPU P-cores", "CPU E-cores", "GPU", "SoC", "SSD", "Battery", "Ambient"] {
        let vals = curatedValues[group] ?? []
        if vals.isEmpty { print("\(group): (none)"); continue }
        let avg = vals.reduce(0, +) / Double(vals.count)
        print("\(group): n=\(vals.count) avg=\(String(format: "%.1f", avg))°C max=\(String(format: "%.1f", vals.max()!))°C")
    }

    let hid = hidCrossCheck()
    print("\n--- HID cross-check (same instant) ---")
    print("HID NAND CH0 temp: \(hid.nand.map { String(format: "%.1f°C", $0) } ?? "n/a")  (SMC SSD avg above)")
    print("HID gas gauge battery: \(hid.battery.map { String(format: "%.1f°C", $0) } ?? "n/a")  (SMC Battery avg above)")
    exit(0)
}

// MARK: - Curated SMC key lists (Fix round 1). See docs/findings/temps.md
// "Final mapping" for the 3-load delta evidence behind each assignment,
// including confidence caveats (TC1x-TC3x/TC4x-TC5x split is medium
// confidence; Tg->GPU is high confidence; Td->SSD disagrees with HID's NAND
// reading by ~13-15C, flagged, not resolved here).
enum SMCCuratedKeys {
    // TC1x/TC2x/TC3x: the 3 groups that rose most under the P-core-only
    // load (+8.5..+16.0C) vs TC4x/TC5x (+5.4..+6.4C).
    static let cpuP: [String] = [
        "TC10", "TC11", "TC12", "TC13",
        "TC20", "TC21", "TC22", "TC23",
        "TC30", "TC31", "TC32", "TC33",
    ]
    // TC4x/TC5x: weakest responders to ALL THREE load types (P, E, and GPU)
    // -- best available candidate for the 2 low-power E-cores by elimination.
    static let cpuE: [String] = ["TC40", "TC41", "TC42", "TC43", "TC50", "TC51", "TC52", "TC53"]
    // Tg family: cleanest signal in the whole dataset -- tight +25.6..+25.7C
    // under isolated GPU load, ~0-8C under CPU-only loads.
    static let gpu: [String] = ["Tg04", "Tg05", "Tg0C", "Tg0D", "Tg0K", "Tg0L", "Tg0S", "Tg0T"]
    // Tp family ("power" stage/VRM candidate): reacts to every load type
    // tested, more strongly than TC -- a general board/power-delivery
    // heat indicator. NOTE: production SoC reading is HID's already-validated
    // SoC/PMU bucket (Task 4); this is offered as an SMC cross-reference.
    static let soc: [String] = [
        "Tp00", "Tp01", "Tp02", "Tp04", "Tp05", "Tp06", "Tp08", "Tp09", "Tp0A",
        "Tp0C", "Tp0D", "Tp0E", "Tp0G", "Tp0H", "Tp0I", "Tp0K", "Tp0L", "Tp0M",
        "Tp0O", "Tp0P", "Tp0Q", "Tp0S", "Tp0T", "Tp0U", "Tp0W", "Tp0X", "Tp0Y",
        "Tp0a", "Tp0b", "Tp0c",
    ]
    static let ssd: [String] = [
        "Td00", "Td01", "Td02", "Td04", "Td05", "Td06", "Td08", "Td09",
        "Td0A", "Td0C", "Td0D", "Td0E", "Td0G", "Td0H", "Td0I", "Td0K", "Td0L", "Td0M",
    ]
    static let battery: [String] = ["TB0T", "TB1T", "TB2T"]
    static let ambient: [String] = ["TAOL"]
}

// MARK: - HID temperature read (Task 4 original; unchanged default behavior)

let type = Int64(kSMHIDEventTypeTemperature)
let field = Int32(type << 16)

// MARK: - Client setup

let client: IOHIDEventSystemClient
if let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) { client = c; print("client: full") }
else { client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault); print("client: simple (fallback)") }

let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
_ = IOHIDEventSystemClientSetMatching(client, matching)

let clock = ContinuousClock()

var noEventNames: [String] = []

func readAll(_ services: [IOHIDServiceClient]) -> [(String, Double)] {
    var out: [(String, Double)] = []
    for svc in services {
        let name = IOHIDServiceClientCopyProperty(svc, "Product" as CFString) as? String ?? "?"
        guard let ev = IOHIDServiceClientCopyEvent(svc, type, 0, 0) else {
            noEventNames.append(name)
            continue
        }
        out.append((name, IOHIDEventGetFloatValue(ev, field)))
    }
    return out
}

// MARK: - Cost: service enumeration alone

var services: [IOHIDServiceClient] = []
let enumCost = clock.measure {
    services = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
}
print("service enumeration: n=\(services.count) cost=\(enumCost)")

// MARK: - Cost: a "full read" = fresh service enumeration + reading every service

var freshServices: [IOHIDServiceClient] = []
var freshReadings: [(String, Double)] = []
let fullReadCost = clock.measure {
    freshServices = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
    freshReadings = readAll(freshServices)
}
print("full read (enumerate + read): services=\(freshServices.count) readings=\(freshReadings.count) cost=\(fullReadCost)")

// MARK: - Cost: re-read using the cached service list (no re-enumeration)

var readings: [(String, Double)] = []
let cachedReadCost = clock.measure {
    readings = readAll(services)
}
print("cached read (reuse service list): services=\(services.count) readings=\(readings.count) cost=\(cachedReadCost)")

for (n, v) in readings.sorted(by: { $0.0 < $1.0 }) {
    print(n.padding(toLength: 36, withPad: " ", startingAt: 0) + String(format: "%6.1f °C", v))
}

// MARK: - Curated grouping
//
// On this Mac (M1 Max) + macOS build, the HID "Product" names carry NO
// per-core-type tag (no "pACC"/"eACC" as the brief anticipated) — everything
// compute-adjacent is generically prefixed "PMU". See docs/findings/temps.md
// for the under-load delta analysis that drove this grouping; CPU-P / CPU-E /
// GPU could NOT be reliably separated from this sensor family on this machine.

struct Group { var label: String; var pattern: (String) -> Bool }

let groups: [Group] = [
    Group(label: "CPU P-cores", pattern: { _ in false }),   // not separable here; see findings
    Group(label: "CPU E-cores", pattern: { _ in false }),   // not separable here; see findings
    Group(label: "GPU", pattern: { _ in false }),           // not separable here; see findings
    Group(label: "SoC/PMU (die + thermal-pad, CPU+GPU unsplit)", pattern: { $0.hasPrefix("PMU tdie") || $0.hasPrefix("PMU tdev") || $0.hasPrefix("PMU TP") || $0.hasPrefix("PMU tcal") }),
    Group(label: "SSD (NAND)", pattern: { $0.hasPrefix("NAND") }),
    Group(label: "Battery", pattern: { $0.contains("gas gauge battery") }),
    Group(label: "Airflow/ambient", pattern: { _ in false }), // none observed
]

// dedupe: average readings that share an exact name (see findings — most
// names here are reported by 2 (sometimes 4) distinct services).
var byName: [String: [Double]] = [:]
for (n, v) in readings { byName[n, default: []].append(v) }
let deduped: [(String, Double)] = byName.map { ($0.key, $0.value.reduce(0, +) / Double($0.value.count)) }

print("\n--- curated groups (deduped by name, averaged) ---")
var unmatched: [String] = []
for g in groups {
    let members = deduped.filter { g.pattern($0.0) }
    if members.isEmpty {
        print("\(g.label): (none)")
        continue
    }
    let vals = members.map(\.1)
    let avg = vals.reduce(0, +) / Double(vals.count)
    let max = vals.max()!
    print("\(g.label): n=\(members.count) avg=\(String(format: "%.1f", avg))°C max=\(String(format: "%.1f", max))°C")
}
for (n, _) in deduped where !groups.contains(where: { $0.pattern(n) }) {
    unmatched.append(n)
}
if !unmatched.isEmpty {
    print("Unmatched: \(unmatched)")
}

if !noEventNames.isEmpty {
    print("No-event services (stuck/garbage, filter these): \(Set(noEventNames).sorted())")
}

print("\nthermalState:", ProcessInfo.processInfo.thermalState.rawValue)
