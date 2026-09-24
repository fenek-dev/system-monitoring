import Foundation
import CPrivate

func pad(_ s: String, _ n: Int = 30) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }

// MARK: - pmgr voltage-states -> MHz tables (IORegistry, no root needed)
// Format (reverse-engineered / matches known asitop-style tools): each entry is
// 8 bytes: UInt32 LE frequency-in-Hz, UInt32 LE voltage-in-mV. Confirmed by
// decoding this machine's own ioreg dump: voltage-states1-sram gave
// 600/972/1332/1704/2064 MHz (5 states) which is exactly an M1-family ECPU table.

func hexDecodeBytes(_ s: Substring) -> [UInt8] {
    var bytes = [UInt8]()
    bytes.reserveCapacity(s.count / 2)
    var it = s.makeIterator()
    while let hi = it.next(), let lo = it.next() {
        if let b = UInt8(String([hi, lo]), radix: 16) { bytes.append(b) }
    }
    return bytes
}

func readPMGRVoltageStates() -> [String: [Double]] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    task.arguments = ["-l", "-w0", "-c", "AppleARMIODevice", "-n", "pmgr"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do { try task.run() } catch { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    guard let text = String(data: data, encoding: .utf8) else { return [:] }
    guard let re = try? NSRegularExpression(pattern: "\"(voltage-states[0-9]+(?:-sram)?)\" = <([0-9a-fA-F]+)>") else { return [:] }
    var out: [String: [Double]] = [:]
    for lineSub in text.split(separator: "\n") {
        let line = String(lineSub)
        guard let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
        guard let kr = Range(m.range(at: 1), in: line), let hr = Range(m.range(at: 2), in: line) else { continue }
        let bytes = hexDecodeBytes(line[hr])
        var freqsHz: [Double] = []
        var i = 0
        while i + 8 <= bytes.count {
            let f = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
            freqsHz.append(Double(f))
            i += 8
        }
        out[String(line[kr])] = freqsHz.map { $0 / 1e6 }
    }
    return out
}

let pmgrTables = readPMGRVoltageStates()
print("=== pmgr voltage-states* found: \(pmgrTables.keys.sorted().joined(separator: ", ")) ===")
// Empirically on this M1 Max: voltage-states1-sram=ECPU, voltage-states5-sram=PCPU, voltage-states9=GPU.
// Names are chip-specific (differ on M2/M3/M4) -- see docs/findings/ioreport.md.
let ecpuMHz = pmgrTables["voltage-states1-sram"] ?? []
let pcpuMHz = pmgrTables["voltage-states5-sram"] ?? []
let gpuMHz = pmgrTables["voltage-states9"] ?? []
print("  ECPU table (voltage-states1-sram): \(ecpuMHz.map { Int($0) })")
print("  PCPU table (voltage-states5-sram): \(pcpuMHz.map { Int($0) })")
print("  GPU  table (voltage-states9):      \(gpuMHz.map { Int($0) })")

// avg active frequency from a residency channel + a P-state->MHz table.
// Convention: state 0 is the idle/off state (not in the freq table), states
// 1...N line up with table[0...N-1]. Returns nil if counts don't line up.
func avgActiveMHz(_ ch: CFDictionary, table: [Double]) -> Double? {
    let n = Int(IOReportStateGetCount(ch))
    guard n == table.count + 1 else { return nil }
    var num = 0.0, den = 0.0
    for i in 1..<n {
        let r = Double(IOReportStateGetResidency(ch, Int32(i)))
        num += r * table[i - 1]
        den += r
    }
    return den > 0 ? num / den : nil
}

// MARK: - discover every group/subgroup IOReport exposes, with channel counts

struct GKey: Hashable { let group: String; let subgroup: String }
// IOReportCopyChannelsInGroup(nil, nil, ...) returns nil in practice (group is
// required) -- IOReportCopyAllChannels(0,0) is the real "list everything" call.
if let all = IOReportCopyAllChannels(0, 0) ?? IOReportCopyChannelsInGroup(nil, nil, 0, 0, 0) {
    let chans = ((all as NSDictionary)["IOReportChannels"] as? [NSDictionary]) ?? []
    var counts: [GKey: Int] = [:]
    for nsCh in chans {
        let ch = nsCh as CFDictionary
        let g = IOReportChannelGetGroup(ch) as String? ?? "?"
        let sg = IOReportChannelGetSubGroup(ch) as String? ?? ""
        counts[GKey(group: g, subgroup: sg), default: 0] += 1
    }
    print("=== all groups/subgroups: \(counts.count) unique pairs, \(chans.count) channels total ===")
    for k in counts.keys.sorted(by: { ($0.group, $0.subgroup) < ($1.group, $1.subgroup) }) {
        print("  \(pad(k.group, 28)) / \(pad(k.subgroup, 34)) n=\(counts[k]!)")
    }
} else {
    print("=== full-channel discovery failed (both IOReportCopyAllChannels and CopyChannelsInGroup(nil,nil) returned nil) ===")
}

// MARK: - build the channel set we actually subscribe to

// No separate top-level "ANE"/media-engine group exists on this SoC (confirmed
// by the full discovery dump above): ANE0/AVE0/ISP0/MSR0/DCS0/AMCC0 all live as
// individual channels inside the "Energy Model" group, so pulling that group
// already gets them.
let desired = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)!
IOReportMergeChannels(desired, IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0), nil)
IOReportMergeChannels(desired, IOReportCopyChannelsInGroup("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0), nil)
IOReportMergeChannels(desired, IOReportCopyChannelsInGroup("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0), nil)

var subscribedRef: Unmanaged<CFMutableDictionary>?
guard let sub = IOReportCreateSubscription(nil, desired, &subscribedRef, 0, nil), let subscribedU = subscribedRef else {
    print("IOReportCreateSubscription failed"); exit(1)
}
let subscribed = subscribedU.takeUnretainedValue()

let clock = ContinuousClock()

// per-sample cost: measure several back-to-back IOReportCreateSamples calls.
var costs: [Duration] = []
var lastSample: CFDictionary!
for _ in 0..<5 {
    var s: CFDictionary!
    let c = clock.measure { s = IOReportCreateSamples(sub, subscribed, nil) }
    costs.append(c)
    lastSample = s
}
let costsMs = costs.map { Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15 }
print(String(format: "=== sample cost over %d calls: min=%.3fms avg=%.3fms max=%.3fms ===",
             costsMs.count, costsMs.min()!, costsMs.reduce(0, +) / Double(costsMs.count), costsMs.max()!))

var s0: CFDictionary! = lastSample
let t0 = Date()
Thread.sleep(forTimeInterval: 1)
let s1 = IOReportCreateSamples(sub, subscribed, nil)!
let dt = Date().timeIntervalSince(t0)
let delta = IOReportCreateSamplesDelta(s0, s1, nil)!
let channels = ((delta as NSDictionary)["IOReportChannels"] as? [NSDictionary]) ?? []
print("channels=\(channels.count) dt=\(String(format: "%.3f", dt))s")

let idleStates: Set<String> = ["IDLE", "OFF", "DOWN"]
var seenStateNames = Set<String>()
for nsCh in channels {
    let ch = nsCh as CFDictionary
    let group = IOReportChannelGetGroup(ch) as String? ?? ""
    let name = IOReportChannelGetChannelName(ch) as String? ?? ""
    if group == "Energy Model" {
        let unit = IOReportChannelGetUnitLabel(ch) as String? ?? ""
        let raw = Double(IOReportSimpleGetIntegerValue(ch, 0))
        let div: Double = ["mJ": 1e3, "uJ": 1e6, "nJ": 1e9][unit] ?? 1
        let watts = raw / div / dt
        if watts > 0.001 || ProcessInfo.processInfo.environment["IOREPORT_ALL_E"] != nil {
            print("  E  " + pad(name) + String(format: "%7.3f W  [%@]", watts, unit as NSString))
        }
    } else {
        var total: Int64 = 0, idle: Int64 = 0
        for i in 0..<IOReportStateGetCount(ch) {
            let s = IOReportStateGetNameForIndex(ch, i) as String? ?? ""
            let r = IOReportStateGetResidency(ch, i)
            total += r
            if idleStates.contains(s) { idle += r }
            seenStateNames.insert(s)
        }
        let active = total > 0 ? Double(total - idle) / Double(total) * 100 : 0
        var line = "  R  " + pad("\(group)/\(name)") + String(format: "%6.1f %% active", active)
        let upper = name.uppercased()
        var table: [Double]? = nil
        if upper.hasPrefix("ECPU") { table = ecpuMHz }
        else if upper.hasPrefix("PCPU") { table = pcpuMHz }
        else if upper.contains("GPU") { table = gpuMHz }
        if let table = table, let mhz = avgActiveMHz(ch, table: table) {
            line += String(format: "  avg~%.0fMHz", mhz)
        }
        print(line)
        if group == "GPU Stats" || upper.hasPrefix("ANE") || group == "AVE Stats" || name.hasSuffix("CPM") || name.hasSuffix("CPM1") {
            var detail: [String] = []
            for i in 0..<IOReportStateGetCount(ch) {
                let sName = IOReportStateGetNameForIndex(ch, i) as String? ?? ""
                let r = IOReportStateGetResidency(ch, i)
                detail.append("\(sName)=\(r)")
            }
            print("       states: " + detail.joined(separator: " "))
        }
    }
}
print("state names seen (\(seenStateNames.count)):", seenStateNames.sorted().prefix(40).joined(separator: " "))
