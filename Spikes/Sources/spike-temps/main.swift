import Foundation
import IOKit.hidsystem
import CPrivate

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
