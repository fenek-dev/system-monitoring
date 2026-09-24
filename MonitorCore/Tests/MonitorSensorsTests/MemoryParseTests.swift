import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct MemoryParseTests {
    static let raw = MemoryRaw(
        pageSize: 16_384, total: 64 << 30,
        freeCount: 1_000, activeCount: 2_000, inactiveCount: 3_000, speculativeCount: 400, wireCount: 500,
        purgeableCount: 60, externalCount: 700, internalCount: 800,
        compressorCount: 90, uncompressedInCompressor: 270,
        pageins: 11, pageouts: 12, swapins: 13, swapouts: 14,
        swapTotal: 2 << 30, swapUsed: 1 << 29, swapFiles: 2,
        pressureLevel: 1, freePercent: 92
    )

    @Test func pageClassesBecomeBytesAndFreeExcludesSpeculative() {
        let r = MemoryParser.reading(Self.raw)
        let p: UInt64 = 16_384
        #expect(r.pageSize == p)
        #expect(r.total == 64 << 30)
        #expect(r.free == 600 * p)            // vm_stat "Pages free" = free_count − speculative_count
        #expect(r.speculative == 400 * p)
        #expect(r.active == 2_000 * p)
        #expect(r.inactive == 3_000 * p)
        #expect(r.wired == 500 * p)
        #expect(r.purgeable == 60 * p)
        #expect(r.fileBacked == 700 * p)
        #expect(r.anonymous == 800 * p)
        #expect(r.compressorBytes == 90 * p)                  // "occupied by compressor"
        #expect(r.compressedOriginalBytes == 270 * p)         // "stored in compressor"
    }

    @Test func eventCountersStayPageCounts() {
        let r = MemoryParser.reading(Self.raw)
        #expect([r.pageins, r.pageouts, r.swapins, r.swapouts] == [11, 12, 13, 14])
    }

    @Test func swapAndPressure() {
        let r = MemoryParser.reading(Self.raw)
        #expect(r.swapTotal == 2 << 30)
        #expect(r.swapUsed == 1 << 29)
        #expect(r.swapFileCount == 2)
        #expect(r.pressureLevel == .normal)
        #expect(abs((r.pressureFraction ?? -1) - 0.08) < 1e-9)
    }

    @Test(arguments: [(Int32(1), MemoryPressureLevel.normal), (2, .warning), (4, .critical)])
    func pressureLevels(_ raw: Int32, _ level: MemoryPressureLevel) {
        #expect(MemoryParser.pressureLevel(raw) == level)
    }

    @Test func unknownPressureInputsAreNil() {
        #expect(MemoryParser.pressureLevel(0) == nil)
        #expect(MemoryParser.pressureLevel(3) == nil)
        #expect(MemoryParser.pressureLevel(nil) == nil)
        #expect(MemoryParser.pressureFraction(freePercent: nil) == nil)
        #expect(MemoryParser.pressureFraction(freePercent: -3) == nil)
        #expect(MemoryParser.pressureFraction(freePercent: 150) == nil)
        #expect(MemoryParser.pressureFraction(freePercent: 0) == 1)
    }

    @Test func speculativeAboveFreeIsGuarded() {
        var raw = Self.raw
        raw.speculativeCount = raw.freeCount + 5
        #expect(MemoryParser.reading(raw).free == 0)
    }

    @Test func byteConversionSaturates() {
        var raw = Self.raw
        raw.activeCount = .max
        #expect(MemoryParser.reading(raw).active == .max)
    }

    /// Raw counters and `vm_stat` captured back to back on this Mac (`TELLTALE_W6A_CAPTURE=1`).
    @Test func capturedCountersMatchVMStat() throws {
        let raw = try JSONDecoder().decode(MemoryRaw.self, from: W6aFixture.data("memory_raw.json"))
        let vm = VMStatText.parse(try W6aFixture.string("vm_stat.txt"))
        let r = MemoryParser.reading(raw)
        #expect(vm.pageSize == r.pageSize)
        func close(_ bytes: UInt64, _ key: String) -> Bool {
            guard let pages = vm.pages[key] else { return false }
            let ref = Double(pages * vm.pageSize)
            return abs(Double(bytes) - ref) <= max(0.1 * ref, Double(4_096 * r.pageSize))
        }
        #expect(close(r.free, "Pages free"))
        #expect(close(r.active, "Pages active"))
        #expect(close(r.inactive, "Pages inactive"))
        #expect(close(r.speculative, "Pages speculative"))
        #expect(close(r.wired, "Pages wired down"))
        #expect(close(r.fileBacked, "File-backed pages"))
        #expect(close(r.anonymous, "Anonymous pages"))
        #expect(close(r.compressorBytes, "Pages occupied by compressor"))
        #expect(close(r.compressedOriginalBytes ?? 0, "Pages stored in compressor"))
        #expect(r.swapins == vm.pages["Swapins"])
    }
}

/// Test-side reader for `vm_stat` output (reference tool).
enum VMStatText {
    static func parse(_ text: String) -> (pageSize: UInt64, pages: [String: UInt64]) {
        var size: UInt64 = 0
        var pages: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Mach Virtual Memory Statistics"), let r = line.range(of: "page size of ") {
                size = UInt64(line[r.upperBound...].prefix { $0.isNumber }) ?? 0
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            if let v = UInt64(value) { pages[key] = v }
        }
        return (size, pages)
    }
}
