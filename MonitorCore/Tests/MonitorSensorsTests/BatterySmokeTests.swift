import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// `TELLTALE_HW_TESTS=1 scripts/test.sh BatterySmokeTests`. Reference: `ioreg -rn AppleSmartBattery`, `pmset -g batt`.
@Suite(.enabled(if: W6bFixture.hardwareTests), .serialized, .w6bExclusive, .offCooperativePool)
struct BatterySmokeTests {
    static let sourceKeys: Set<String> = [
        "Current Capacity", "Max Capacity", "Is Charging", "Is Present", "Power Source State", "Time to Empty",
        "Time to Full Charge", "BatteryHealth", "BatteryHealthCondition", "Type",
    ]
    static let adapterKeys: Set<String> = ["Watts", "Name", "Current", "AdapterVoltage", "IsWireless"]

    private func ioregInt(_ text: String, _ key: String) -> Int? {
        text.split(separator: "\n").first { $0.contains("\"\(key)\" = ") }
            .flatMap { Int($0.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") }
    }

    @Test func matchesIoregAndPmset() throws {
        let sensor = BatterySensor()
        try sensor.prepare()
        defer { sensor.invalidate() }
        if W6bFixture.capture {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            defer { if svc != 0 { IOObjectRelease(svc) } }
            let raw = BatterySensor.raw(service: svc)
            var dump: [String: Any] = [:]
            if var reg = raw.registry?.filter({ BatteryParse.registryKeys.contains($0.key) }) {
                if let bd = reg["BatteryData"] as? [String: Any] { reg["BatteryData"] = ["CellVoltage": bd["CellVoltage"] ?? []] }
                if let ad = reg["AdapterDetails"] as? [String: Any] { reg["AdapterDetails"] = ad.filter { Self.adapterKeys.contains($0.key) } }
                dump["registry"] = reg
            }
            dump["source"] = raw.source?.filter { Self.sourceKeys.contains($0.key) }
            dump["providing"] = raw.providing
            dump["adapter"] = raw.adapter?.filter { Self.adapterKeys.contains($0.key) }
            try PropertyListSerialization.data(fromPropertyList: dump, format: .xml, options: 0)
                .write(to: W6bFixture.sourceURL("battery.plist"))
        }
        let r = try sensor.sample(SampleContext()).reading
        let ioreg = try W6bFixture.run(["/usr/sbin/ioreg", "-rn", "AppleSmartBattery"])
        let pmset = try W6bFixture.run(["/usr/bin/pmset", "-g", "batt"])
        let pct = pmset.split(separator: "\t").last.flatMap { Double($0.prefix { $0.isNumber }) }
        let pmsetAC = pmset.contains("'AC Power'")
        // "charging" and "finishing charge" (trickle near 100 %) both mean charging; "charged"/"not charging" do not.
        let pmsetCharging = pmset.contains("; charging;") || pmset.contains("; finishing charge;")
        print("W6b battery: \(Int(r.percent ?? -1))% charging=\(r.isCharging) ac=\(r.onAC) cycles=\(r.cycleCount ?? -1) "
              + String(format: "design=%.1fWh max=%.1fWh cur=%.1fWh health=%.1f%% V=%.2f A=%.2f T=%.1f°C ", r.designCapacityWh ?? -1,
                       r.maxCapacityWh ?? -1, r.currentCapacityWh ?? -1, 100 * (r.maxCapacityWh ?? 0) / (r.designCapacityWh ?? 1),
                       r.voltageV ?? -1, r.amperageA ?? -99, r.temperatureC ?? -1)
              + "toFull=\(r.minutesToFull ?? -1) toEmpty=\(r.minutesToEmpty ?? -1) cond=\(r.condition ?? "-") adapter=\(r.adapterName ?? "-") lpm=\(r.lowPowerMode)"
              + " calculating=\(r.timeRemainingCalculating) | pmset: \(pct ?? -1)% ac=\(pmsetAC) charging=\(pmsetCharging)")
        // Desktop (no AppleSmartBattery in ioreg): only "no battery, on AC" can be checked.
        guard ioreg.contains("AppleSmartBattery") else {
            #expect(!r.present && r.onAC)
            return
        }
        #expect(r.present)
        if pmset.contains("(no estimate)") { #expect(r.timeRemainingCalculating) }
        #expect(r.cycleCount == ioregInt(ioreg, "CycleCount"))
        let design = try #require(ioregInt(ioreg, "DesignCapacity")), rawMax = try #require(ioregInt(ioreg, "AppleRawMaxCapacity"))
        let health = try #require(r.maxCapacityWh.flatMap { m in r.designCapacityWh.map { m / $0 } })
        #expect(abs(health - Double(rawMax) / Double(design)) < 0.01)
        if let pct { #expect(abs((r.percent ?? -1) - pct) <= 1) }
        #expect(r.onAC == pmsetAC)
        #expect(r.isCharging == pmsetCharging)
        if let t = ioregInt(ioreg, "Temperature") { #expect(abs((r.temperatureC ?? 0) - Double(t) / 100) < 0.5) }
        if r.isCharging { #expect((r.amperageA ?? 0) > 0) }
        if !r.onAC { #expect((r.amperageA ?? 0) < 0) }
        #expect(r.lowPowerMode == ProcessInfo.processInfo.isLowPowerModeEnabled)
        #expect((r.voltageV ?? 0) > 9 && (r.voltageV ?? 0) < 14)
    }

    @Test func bench() throws {
        let sensor = BatterySensor()
        try sensor.prepare()
        defer { sensor.invalidate() }
        var ns: [UInt64] = []
        for _ in 0..<30 {
            let t = w6bUptimeNs()
            _ = try sensor.sample(SampleContext())
            ns.append(w6bUptimeNs() - t)
        }
        print("W6b bench battery \(w6bPercentiles(ns))")
    }
}
