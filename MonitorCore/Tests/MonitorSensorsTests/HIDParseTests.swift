import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// Parse layer on a captured HID read (`Fixtures/W6b/hid_samples.json`, M1 Max, 63 live services).
struct HIDParseTests {
    private let catalog = try! TemperatureCatalog.bundled()

    @Test func capturedServicesDedupeAndGroup() throws {
        let samples = try W6bFixture.decode("hid_samples.json", as: [HIDTemperatureParse.Sample].self)
        #expect(samples.count > 50)
        let r = HIDTemperatureParse.reading(samples, catalog: catalog).sensors
        let names = Set(samples.map(\.name))
        #expect(r.count == names.count - 1)                          // minus PMU tcal
        #expect(r.map(\.name) == r.map(\.name).sorted())
        #expect(r.first { $0.name == "NAND CH0 temp" }?.group == .ssd)
        #expect(r.first { $0.name == "gas gauge battery" }?.group == .battery)
        #expect(r.filter { $0.group == .soc }.count >= 20)
        #expect(!r.contains { $0.group == .cpuPerformance || $0.group == .cpuEfficiency || $0.group == .gpu })
        // duplicate services are averaged, not first-wins
        let dup = samples.filter { $0.name == "PMU tdie1" }.map(\.celsius)
        #expect(dup.count >= 2)
        let tdie1 = try #require(r.first { $0.name == "PMU tdie1" })
        #expect(abs(tdie1.celsius - dup.reduce(0, +) / Double(dup.count)) < 1e-9)
    }

    @Test func filtersGarbage() {
        let s: [HIDTemperatureParse.Sample] = [
            .init(name: "PMU tdie0", celsius: 50), .init(name: "PMU tdie0", celsius: 52),
            .init(name: "PMU tdie9", celsius: .nan), .init(name: "PMU tdev1", celsius: -100),
            .init(name: "", celsius: 40), .init(name: "PMU tcal", celsius: 51), .init(name: "Mystery", celsius: 33),
        ]
        let r = HIDTemperatureParse.reading(s, catalog: catalog).sensors
        #expect(r.map(\.name) == ["Mystery", "PMU tdie0"])
        #expect(r.map(\.celsius) == [33, 51])
        #expect(r.map(\.group) == [.other, .soc])
        #expect(HIDTemperatureParse.reading(s, catalog: nil).sensors.allSatisfy { $0.group == .other })
    }
}
