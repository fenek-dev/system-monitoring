import Foundation
import MonitorModel

/// Pure battery decoding. `AppleSmartBattery` registry properties are preferred (findings/smc.md): raw capacities,
/// cycles, voltage, signed amperage (two's-complement `UInt64`), `Temperature` (centi-°C). `IOPSCopyPowerSourcesInfo`
/// supplies the UI percentage, charging state, power-source state, time estimates and health label.
enum BatteryParse {
    /// Li-ion nominal cell voltage used to convert mAh → Wh (6075 mAh × 3 cells × 3.85 V = 70.2 Wh, the
    /// rated 70 Wh of MacBookPro18,3/4). Health = max/design is unaffected by this constant.
    static let nominalCellVolts = 3.85
    /// Registry "not available" sentinel for time fields.
    static let timeSentinel = 65535

    /// Keys copied into fixtures (everything else — serial numbers, logs — is dropped).
    static let registryKeys: Set<String> = [
        "BatteryInstalled", "ExternalConnected", "IsCharging", "FullyCharged", "CurrentCapacity", "MaxCapacity",
        "AppleRawCurrentCapacity", "AppleRawMaxCapacity", "DesignCapacity", "NominalChargeCapacity", "CycleCount",
        "Voltage", "Amperage", "InstantAmperage", "Temperature", "VirtualTemperature", "AvgTimeToEmpty", "AvgTimeToFull",
        "TimeRemaining", "PermanentFailureStatus", "AdapterDetails", "BatteryData",
    ]

    static func int(_ d: [String: Any], _ k: String) -> Int? {
        w6bInt64(d[k]).flatMap { Int(exactly: $0) }
    }

    static func bool(_ d: [String: Any], _ k: String) -> Bool? {
        switch d[k] {
        case let b as Bool: b
        case let n as NSNumber: n.boolValue
        case let s as String: s == "Yes" || s == "true"
        default: nil
        }
    }

    /// - Parameters:
    ///   - registry: `AppleSmartBattery` properties (nil: no battery service, e.g. desktops).
    ///   - source: `IOPSGetPowerSourceDescription` of the internal battery (nil if none).
    ///   - providing: `IOPSGetProvidingPowerSourceType` ("AC Power" / "Battery Power").
    ///   - adapter: `IOPSCopyExternalPowerAdapterDetails` (nil when unplugged).
    static func reading(registry: [String: Any]?, source: [String: Any]?, providing: String?,
                        adapter: [String: Any]?, lowPowerMode: Bool) -> BatteryReading {
        let reg = registry ?? [:]
        var r = BatteryReading(lowPowerMode: lowPowerMode)
        let installed = bool(reg, "BatteryInstalled") ?? (registry != nil)
        r.present = installed && (source.flatMap { bool($0, "Is Present") } ?? true)
        r.onAC = providing.map { $0 == "AC Power" } ?? source.flatMap { $0["Power Source State"] as? String }.map { $0 == "AC Power" }
            ?? bool(reg, "ExternalConnected") ?? !r.present
        let adapterDict = adapter ?? (reg["AdapterDetails"] as? [String: Any])
        if r.onAC, let a = adapterDict {
            if let name = a["Name"] as? String, !name.isEmpty {
                r.adapterName = name
            } else if let w = int(a, "Watts"), w > 0 {
                r.adapterName = "\(w) W USB-C"          // DESIGN label when the adapter reports no name
            }
        }
        guard r.present else { return r }

        r.isCharging = source.flatMap { bool($0, "Is Charging") } ?? bool(reg, "IsCharging") ?? false
        if let s = source, let cur = w6bNumber(s["Current Capacity"]), let max = w6bNumber(s["Max Capacity"]), max > 0 {
            r.percent = min(100, Swift.max(0, cur / max * 100))
        } else if let cur = w6bNumber(reg["CurrentCapacity"]), let max = w6bNumber(reg["MaxCapacity"]), max > 0 {
            r.percent = min(100, Swift.max(0, cur / max * 100))
        }
        // Time remaining: IOPS −1 = "still calculating"; registry 65535 = no estimate. Only when NO source has a
        // value and at least one of them says calculating/sentinel do we report `timeRemainingCalculating`.
        // A missing key (e.g. fully charged: no "Time to Full Charge") is simply not available.
        func minutes(_ v: Int?) -> Int? { v.flatMap { $0 >= 0 && $0 < timeSentinel ? $0 : nil } }
        func calculating(_ vs: [Int?]) -> Bool { vs.contains { $0 == -1 || $0 == timeSentinel } }
        if r.isCharging {
            let ps = source.flatMap { int($0, "Time to Full Charge") }, avg = int(reg, "AvgTimeToFull")
            r.minutesToFull = minutes(ps) ?? minutes(avg)
            r.timeRemainingCalculating = r.minutesToFull == nil && calculating([ps, avg])
        } else if !r.onAC {
            let ps = source.flatMap { int($0, "Time to Empty") }, avg = int(reg, "AvgTimeToEmpty")
            let rem = int(reg, "TimeRemaining")
            r.minutesToEmpty = minutes(ps) ?? minutes(avg) ?? minutes(rem)
            r.timeRemainingCalculating = r.minutesToEmpty == nil && calculating([ps, avg, rem])
        }
        r.cycleCount = int(reg, "CycleCount")

        let cells = ((reg["BatteryData"] as? [String: Any])?["CellVoltage"] as? [Any])?.count ?? 0
        let packVolts = w6bNumber(reg["Voltage"]).map { $0 / 1000 }
        let nominal = cells > 0 ? Double(cells) * nominalCellVolts : packVolts
        func wh(_ key: String) -> Double? {
            guard let mAh = w6bNumber(reg[key]), mAh > 0, let v = nominal, v > 0 else { return nil }
            return mAh * v / 1000
        }
        r.designCapacityWh = wh("DesignCapacity")
        r.maxCapacityWh = wh("AppleRawMaxCapacity")
        r.currentCapacityWh = wh("AppleRawCurrentCapacity")
        r.voltageV = packVolts
        // InstantAmperage preferred (live gauge; `Amperage` is smoothed). BatteryReading has one field, so the
        // instant value replaces the smoothed one when present (ruling). Both are two's-complement UInt64 mA.
        r.amperageA = (w6bInt64(reg["InstantAmperage"]) ?? w6bInt64(reg["Amperage"])).map { Double($0) / 1000 }
        r.temperatureC = w6bNumber(reg["Temperature"]).flatMap { $0 > 0 ? $0 / 100 : nil }
        r.condition = source.flatMap { ($0["BatteryHealthCondition"] as? String) ?? ($0["BatteryHealth"] as? String) }
        if r.condition == nil, let pf = int(reg, "PermanentFailureStatus"), pf != 0 { r.condition = "Service Recommended" }
        return r
    }
}
