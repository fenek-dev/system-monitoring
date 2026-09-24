import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Parse layer on a captured MacBookPro18,4 dump (`Fixtures/W6b/battery.plist`: on AC, finishing charge,
/// 1856 cycles, design 6075 mAh, raw max 4395 mAh; serials stripped).
struct BatteryParseTests {
    private func fixture() throws -> (reg: [String: Any], source: [String: Any], providing: String?, adapter: [String: Any]?) {
        let plist = try PropertyListSerialization.propertyList(from: W6bFixture.data("battery.plist"), format: nil)
        let d = try #require(plist as? [String: Any])
        return (try #require(d["registry"] as? [String: Any]), try #require(d["source"] as? [String: Any]),
                d["providing"] as? String, d["adapter"] as? [String: Any])
    }

    @Test func capturedChargingOnAC() throws {
        let f = try fixture()
        let r = BatteryParse.reading(registry: f.reg, source: f.source, providing: f.providing, adapter: f.adapter, lowPowerMode: false)
        #expect(r.present && r.onAC && r.isCharging)
        #expect(r.cycleCount == 1856)
        let design = try #require(r.designCapacityWh), max = try #require(r.maxCapacityWh)
        #expect(abs(design - 6075 * 3 * 3.85 / 1000) < 1e-9)           // 70.2 Wh (3 cells)
        #expect(abs(max / design - 4395.0 / 6075.0) < 1e-9)              // health = AppleRawMaxCapacity / DesignCapacity
        #expect((r.currentCapacityWh ?? 0) <= max * 1.01)
        #expect(r.percent == 100)
        #expect(r.minutesToFull != nil && r.minutesToFull == f.source["Time to Full Charge"] as? Int)
        #expect(r.minutesToEmpty == nil)
        #expect((r.amperageA ?? 0) > 0)                                  // charging current is positive
        #expect(r.voltageV.map { $0 > 12 && $0 < 13 } == true)
        #expect(r.temperatureC.map { $0 > 25 && $0 < 40 } == true)
        #expect(r.condition == "Check Battery")
        #expect(r.adapterName == "100 W USB-C")
        #expect(!r.lowPowerMode && !r.timeRemainingCalculating)
    }

    @Test func instantAmperagePreferred() throws {
        var f = try fixture()
        f.reg["Amperage"] = NSNumber(value: 1000)
        f.reg["InstantAmperage"] = NSNumber(value: 18_446_744_073_709_550_616 as UInt64)   // −1000 mA
        #expect(BatteryParse.reading(registry: f.reg, source: f.source, providing: nil, adapter: nil,
                                     lowPowerMode: false).amperageA == -1)
        f.reg.removeValue(forKey: "InstantAmperage")
        #expect(BatteryParse.reading(registry: f.reg, source: f.source, providing: nil, adapter: nil,
                                     lowPowerMode: false).amperageA == 1)
    }

    @Test func calculatingVsNotAvailable() throws {
        var f = try fixture()
        f.source["Time to Full Charge"] = -1                              // IOPS: calculating
        f.reg["AvgTimeToFull"] = 65535
        var r = BatteryParse.reading(registry: f.reg, source: f.source, providing: "AC Power", adapter: nil, lowPowerMode: false)
        #expect(r.isCharging && r.minutesToFull == nil && r.timeRemainingCalculating)
        f.source.removeValue(forKey: "Time to Full Charge")               // key absent, registry has a value
        f.reg["AvgTimeToFull"] = 42
        r = BatteryParse.reading(registry: f.reg, source: f.source, providing: "AC Power", adapter: nil, lowPowerMode: false)
        #expect(r.minutesToFull == 42 && !r.timeRemainingCalculating)
        f.reg.removeValue(forKey: "AvgTimeToFull")                         // nothing at all → not available
        r = BatteryParse.reading(registry: f.reg, source: f.source, providing: "AC Power", adapter: nil, lowPowerMode: false)
        #expect(r.minutesToFull == nil && !r.timeRemainingCalculating)
        f.source["Is Charging"] = false                                  // on AC, not charging → neither
        f.reg["IsCharging"] = false
        r = BatteryParse.reading(registry: f.reg, source: f.source, providing: "AC Power", adapter: nil, lowPowerMode: false)
        #expect(r.minutesToFull == nil && r.minutesToEmpty == nil && !r.timeRemainingCalculating)
    }

    @Test func readingDecodesOldFixturesWithoutCalculatingFlag() throws {
        let old = #"{"present":true,"isCharging":false,"onAC":false,"lowPowerMode":false,"minutesToEmpty":30}"#
        let r = try JSONDecoder().decode(BatteryReading.self, from: Data(old.utf8))
        #expect(r.present && r.minutesToEmpty == 30 && !r.timeRemainingCalculating)
        let rt = try JSONDecoder().decode(BatteryReading.self,
                                          from: JSONEncoder().encode(BatteryReading(present: true, timeRemainingCalculating: true)))
        #expect(rt.timeRemainingCalculating)
    }

    @Test func dischargingUsesSignedAmperageAndTimeToEmpty() throws {
        var f = try fixture()
        f.reg.removeValue(forKey: "InstantAmperage")
        f.reg["Amperage"] = NSNumber(value: 18_446_744_073_709_548_582 as UInt64)   // two's complement −3034 mA
        f.reg["ExternalConnected"] = false
        f.reg["IsCharging"] = false
        f.reg["AvgTimeToEmpty"] = 312
        f.source["Is Charging"] = false
        f.source["Power Source State"] = "Battery Power"
        f.source["Time to Empty"] = 305
        let r = BatteryParse.reading(registry: f.reg, source: f.source, providing: "Battery Power", adapter: nil, lowPowerMode: true)
        #expect(!r.onAC && !r.isCharging && r.lowPowerMode)
        #expect(r.amperageA == -3.034)
        #expect(r.minutesToEmpty == 305 && r.minutesToFull == nil)
        #expect(r.adapterName == nil)
        f.source["Time to Empty"] = -1                                   // "calculating" → registry average
        let avg = BatteryParse.reading(registry: f.reg, source: f.source, providing: "Battery Power", adapter: nil,
                                       lowPowerMode: false)
        #expect(avg.minutesToEmpty == 312 && !avg.timeRemainingCalculating)
        f.source.removeValue(forKey: "Time to Empty")
        f.reg["AvgTimeToEmpty"] = 65535                                  // sentinel
        f.reg["TimeRemaining"] = 290
        #expect(BatteryParse.reading(registry: f.reg, source: f.source, providing: "Battery Power", adapter: nil,
                                     lowPowerMode: false).minutesToEmpty == 290)
    }

    @Test func registryOnlyFallbacks() throws {
        var f = try fixture()
        f.reg.removeValue(forKey: "BatteryData")                         // no cell count → pack voltage
        let r = BatteryParse.reading(registry: f.reg, source: nil, providing: nil, adapter: nil, lowPowerMode: false)
        #expect(r.present && r.onAC && r.isCharging)                     // ExternalConnected / IsCharging
        #expect(r.percent == 100)                                        // CurrentCapacity / MaxCapacity
        let v = try #require(r.voltageV)
        #expect(abs((r.designCapacityWh ?? 0) - 6075 * v / 1000) < 1e-9)
        #expect(r.adapterName == "100 W USB-C")                          // registry AdapterDetails
        #expect(r.condition == nil)
    }

    @Test func noBattery() {
        let r = BatteryParse.reading(registry: nil, source: nil, providing: "AC Power",
                                     adapter: ["Watts": 150, "Name": "Mac Studio PSU"], lowPowerMode: false)
        #expect(!r.present && r.onAC && r.percent == nil && r.cycleCount == nil)
        #expect(r.adapterName == "Mac Studio PSU")
        let r2 = BatteryParse.reading(registry: nil, source: nil, providing: nil, adapter: nil, lowPowerMode: false)
        #expect(!r2.present && r2.onAC)
    }
}
