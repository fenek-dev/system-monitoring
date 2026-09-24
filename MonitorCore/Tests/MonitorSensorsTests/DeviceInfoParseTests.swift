import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct DeviceInfoParseTests {
    static let m1Max = DeviceRaw(
        hwModel: "MacBookPro18,4", osBuild: "25F71", osVersion: [26, 5, 0],
        productName: "MacBook Pro (14-inch, 2021)", socName: "Apple M1 Max", brandString: "Apple M1 Max",
        performanceCores: 8, efficiencyCores: 2, gpuCores: 32, memoryBytes: 64 << 30, dramType: "LPDDR5",
        bootTimeSec: 1_788_849_529, bootTimeUsec: 500_000, hasBattery: true, fanCount: 2
    )

    @Test func assemblesDeviceInfo() {
        let d = DeviceInfoParser.info(Self.m1Max)
        #expect(d.bootTime.timeIntervalSince1970 == 1_788_849_529.5)
        #expect(d == DeviceInfo(
            hwModel: "MacBookPro18,4", osBuild: "25F71",
            modelName: "MacBook Pro (14-inch, 2021)", chipName: "Apple M1 Max",
            performanceCores: 8, efficiencyCores: 2, gpuCores: 32, neuralEngineCores: 16,
            memoryBytes: 64 << 30, memoryType: "LPDDR5", memoryBandwidth: "400 GB/s",
            bootTime: Date(timeIntervalSince1970: 1_788_849_529.5), osVersion: "macOS 26.5",
            hasBattery: true, fanCount: 2
        ))
    }

    @Test func osVersionFormatting() {
        #expect(DeviceInfoParser.osVersion([26, 5, 0]) == "macOS 26.5")
        #expect(DeviceInfoParser.osVersion([15, 0, 1]) == "macOS 15.0.1")
        #expect(DeviceInfoParser.osVersion([]) == "macOS")
    }

    @Test func fallbacksWhenDeviceTreeNamesMissing() {
        var raw = Self.m1Max
        raw.productName = nil
        raw.socName = nil
        let d = DeviceInfoParser.info(raw)
        #expect(d.modelName == "MacBookPro18,4")
        #expect(d.chipName == "Apple M1 Max")      // brand string
        raw.brandString = nil
        raw.hwModel = nil
        let e = DeviceInfoParser.info(raw)
        #expect(e.modelName == "Mac")
        #expect(e.chipName == "Apple Silicon")
        #expect(e.hwModel == "")
    }

    @Test(arguments: [
        ("Apple M1", 8, "68 GB/s", 16), ("Apple M1 Pro", 16, "200 GB/s", 16), ("Apple M1 Ultra", 64, "800 GB/s", 32),
        ("Apple M2", 10, "100 GB/s", 16), ("Apple M2 Max", 38, "400 GB/s", 16), ("Apple M3 Pro", 18, "150 GB/s", 16),
        ("Apple M3 Max", 30, "300 GB/s", 16), ("Apple M3 Max", 40, "400 GB/s", 16),
        ("Apple M4 Pro", 20, "273 GB/s", 16), ("Apple M4 Max", 32, "410 GB/s", 16), ("Apple M4 Max", 40, "546 GB/s", 16),
    ])
    func chipCatalog(_ chip: String, _ gpu: Int, _ bandwidth: String, _ ane: Int) {
        let spec = ChipCatalog.spec(chip: chip, gpuCores: gpu)
        #expect(spec?.bandwidth == bandwidth)
        #expect(spec?.neuralEngineCores == ane)
    }

    @Test func unknownChipHasNoCatalogEntry() {
        #expect(ChipCatalog.spec(chip: "Apple M9 Hyper", gpuCores: 99) == nil)
        #expect(ChipCatalog.spec(chip: "Intel(R) Core(TM) i9", gpuCores: nil) == nil)
        var raw = Self.m1Max
        raw.socName = "Apple M9 Hyper"
        let d = DeviceInfoParser.info(raw)
        #expect(d.memoryBandwidth == nil && d.neuralEngineCores == nil)
    }

    @Test func nulTerminatedDeviceTreeStrings() {
        #expect(DeviceInfoParser.string(fromDeviceTree: Data("LPDDR5\0\0".utf8)) == "LPDDR5")
        #expect(DeviceInfoParser.string(fromDeviceTree: Data()) == nil)
        #expect(DeviceInfoParser.string(fromDeviceTree: Data("\0".utf8)) == nil)
    }

    /// Raw inputs captured on this Mac (`TELLTALE_W6A_CAPTURE=1`).
    @Test func capturedRawAssembles() throws {
        let raw = try JSONDecoder().decode(DeviceRaw.self, from: W6aFixture.data("device_raw.json"))
        let d = DeviceInfoParser.info(raw)
        #expect(d.hwModel == "MacBookPro18,4")
        #expect(d.chipName == "Apple M1 Max")
        #expect(d.performanceCores == 8 && d.efficiencyCores == 2)
        #expect(d.gpuCores == 32)
        #expect(d.memoryBandwidth == "400 GB/s")
        #expect(d.modelName.hasPrefix("MacBook Pro"))
    }
}
