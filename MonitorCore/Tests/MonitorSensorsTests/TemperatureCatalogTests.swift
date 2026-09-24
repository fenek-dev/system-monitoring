import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

struct TemperatureCatalogTests {
    private let catalog = try! TemperatureCatalog.bundled()

    @Test func glob() {
        #expect(TemperatureCatalog.glob("Tg0?", "Tg0K"))
        #expect(!TemperatureCatalog.glob("Tg0?", "Tg0KK"))
        #expect(!TemperatureCatalog.glob("Tg0?", "tg0K"))            // case-sensitive
        #expect(TemperatureCatalog.glob("TB?T", "TB1T"))
        #expect(!TemperatureCatalog.glob("TB?T", "TB1V"))
        #expect(TemperatureCatalog.glob("NAND*", "NAND CH0 temp"))
        #expect(TemperatureCatalog.glob("*temp", "NAND CH0 temp"))
        #expect(TemperatureCatalog.glob("P*d*e", "PMU tdie"))
        #expect(TemperatureCatalog.glob("*", ""))
        #expect(!TemperatureCatalog.glob("", "x"))
        #expect(TemperatureCatalog.glob("TAOL", "TAOL"))
    }

    @Test func m1MaxModelMatchesAndMapsVerifiedKeys() throws {
        let m = try #require(catalog.model(for: "MacBookPro18,4"))
        #expect(catalog.model(for: "MacBookPro18,1") == m)
        #expect(catalog.model(for: "Mac13,1") == m)
        #expect(m.smc.count == 32)
        func keys(_ g: TemperatureGroup) -> [String] { m.smc.filter { $0.value == g }.map(\.key).sorted() }
        #expect(keys(.cpuPerformance) == ["TC10", "TC11", "TC12", "TC13", "TC20", "TC21", "TC22", "TC23",
                                           "TC30", "TC31", "TC32", "TC33"])
        #expect(keys(.cpuEfficiency) == ["TC40", "TC41", "TC42", "TC43", "TC50", "TC51", "TC52", "TC53"])
        #expect(keys(.gpu) == ["Tg04", "Tg05", "Tg0C", "Tg0D", "Tg0K", "Tg0L", "Tg0S", "Tg0T"])
        #expect(keys(.battery) == ["TB0T", "TB1T", "TB2T"])
        #expect(keys(.airflow) == ["TAOL"])
        #expect(keys(.ssd).isEmpty)                                   // SSD comes from HID NAND (see temps.md)
        #expect(catalog.smcGroup("TC12", model: m) == .cpuPerformance)
        #expect(catalog.smcGroup("Tp01", model: m) == nil)            // known model: exact keys only
    }

    @Test func unknownModelUsesGenericFamilies() {
        #expect(catalog.model(for: "Mac15,3") == nil)
        #expect(catalog.model(for: "Mac13,2") == nil)                 // M1 Ultra: not verified
        #expect(catalog.model(for: "") == nil)
        #expect(catalog.smcGroup("Te05", model: nil) == .cpuEfficiency)
        #expect(catalog.smcGroup("Tf04", model: nil) == .cpuPerformance)
        #expect(catalog.smcGroup("Tp0D", model: nil) == .cpuPerformance)
        #expect(catalog.smcGroup("Tg0f", model: nil) == .gpu)
        #expect(catalog.smcGroup("TB0T", model: nil) == .battery)
        #expect(catalog.smcGroup("TAOL", model: nil) == .airflow)
        #expect(catalog.smcGroup("TW0P", model: nil) == nil)
    }

    @Test func longestPrefixWins() {
        let a = TemperatureCatalog.Model(name: "a", prefixes: ["Mac"], smc: ["TA": .soc])
        let b = TemperatureCatalog.Model(name: "b", prefixes: ["Mac14,"], smc: ["TB": .gpu])
        let c = TemperatureCatalog(version: 1, models: [a, b], generic: [], hid: [], hidIgnore: [])
        #expect(c.model(for: "Mac14,2")?.name == "b")
        #expect(c.model(for: "Mac15,2")?.name == "a")
    }

    @Test func hidNames() {
        #expect(catalog.hidGroup("NAND CH0 temp") == .ssd)
        #expect(catalog.hidGroup("gas gauge battery") == .battery)
        #expect(catalog.hidGroup("PMU tdie3") == .soc)
        #expect(catalog.hidGroup("PMU tdev8") == .soc)
        #expect(catalog.hidGroup("PMU TP1g") == .soc)
        #expect(catalog.hidGroup("PMU tcal") == nil)                  // calibration constant, dropped
        #expect(catalog.hidGroup("Something new") == .other)
    }
}
