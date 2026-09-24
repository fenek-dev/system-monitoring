import Foundation
import MonitorModel
import Testing
@testable import MonitorUIKit

/// DESIGN §5 samples. Locale fixed to en_US (the design's samples are en-US).
@Suite struct TTFormatTests {
    init() { TTFormat.locale = Locale(identifier: "en_US") }

    let bytes = UnitPreferences()
    let bits = UnitPreferences(networkRate: .bits)
    let fahrenheit = UnitPreferences(temperature: .fahrenheit)

    static let KiB: UInt64 = 1024, MiB: UInt64 = 1024 * 1024, GiB: UInt64 = 1024 * 1024 * 1024

    // MARK: §5.1

    @Test func unavailableIsEmDash() {
        #expect(TTFormat.percent(nil) == "—")
        #expect(TTFormat.percent(.nan) == "—")
        #expect(TTFormat.percent(-0.2) == "—")
        #expect(TTFormat.cpuPercent(nil) == "—")
        #expect(TTFormat.bytes(nil) == "—")
        #expect(TTFormat.rate(nil, units: bytes) == "—")
        #expect(TTFormat.temperature(nil, units: bytes) == "—")
        #expect(TTFormat.watts(nil) == "—")
        #expect(TTFormat.frequency(nil) == "—")
        #expect(TTFormat.duration(nil) == "—")
        #expect(TTFormat.cpuTime(nil) == "—")
        #expect(TTFormat.count(nil) == "—")
        #expect(TTFormat.rpm(nil) == "—")
        #expect(TTFormat.rpm(.infinity) == "—")
    }

    @Test func neverNegativeZeroAndUnicodeMinus() {
        #expect(TTFormat.watts(-0.01) == "0.0 W")
        #expect(TTFormat.watts(-18.9) == "−18.9 W")
        #expect(TTFormat.dBm(-52) == "−52 dBm")
    }

    // MARK: §5.2 Percent

    @Test func percent() {
        #expect(TTFormat.percent(0.34) == "34%")
        #expect(TTFormat.percent(0.29) == "29%")
        #expect(TTFormat.percent(0.221, digits: 1) == "22.1%")
        #expect(TTFormat.percent(0) == "0%")
        #expect(TTFormat.percent(0.125) == "12%") // half-to-even
        #expect(TTFormat.percent(0.135) == "14%")
    }

    @Test func cpuPercent() {
        #expect(TTFormat.cpuPercent(212.4) == "212.4%")
        #expect(TTFormat.cpuPercent(0.4) == "0.4%")
        #expect(TTFormat.cpuPercent(96.1) == "96.1%")
        #expect(TTFormat.cpuPercent(1180.44) == "1,180.4%")
        #expect(TTFormat.cpuPercent(212.4, sign: false) == "212.4")
        #expect(TTFormat.cpuPercentInteger(212.4) == "212%")
        #expect(TTFormat.cpuPercentInteger(812) == "812%")
        #expect(TTFormat.percentValue(0.0, digits: 1) == "0.0%")
    }

    // MARK: §5.3 Bytes

    @Test func memoryDetail() {
        #expect(TTFormat.bytes(UInt64(3.82 * Double(Self.GiB))) == "3.82 GB")
        #expect(TTFormat.bytes(894 * Self.MiB) == "894 MB")
        #expect(TTFormat.bytes(492 * Self.MiB) == "492 MB")
        #expect(TTFormat.bytes(12 * Self.KiB) == "12 KB")
        #expect(TTFormat.bytes(0) == "0 KB")
        #expect(TTFormat.bytes(UInt64(5.10 * Double(Self.GiB))) == "5.10 GB")
        #expect(TTFormat.bytes(UInt64(1.24 * 1024 * Double(Self.GiB))) == "1.24 TB")
        // Rounding up across the unit boundary promotes the unit.
        #expect(TTFormat.bytes(Self.GiB - 100) == "1.00 GB")
    }

    @Test func memoryHeadline() {
        #expect(TTFormat.memory(UInt64(15.1 * Double(Self.GiB)), style: .headline) == "15.1 GB")
        #expect(TTFormat.memory(UInt64(15.2 * Double(Self.GiB)), style: .headline) == "15.2 GB")
        #expect(TTFormat.memory(894 * Self.MiB, style: .headline) == "894 MB")
        #expect(TTFormat.memory(UInt64(1.2 * Double(Self.GiB)), style: .swap) == "1.20 GB")
        #expect(TTFormat.memory(2 * Self.GiB, style: .swap) == "2.00 GB")
        #expect(TTFormat.memory(24 * Self.GiB, style: .total) == "24 GB")
        #expect(TTFormat.memory(24 * Self.GiB, style: .totalPrecise) == "24.0 GB")
    }

    @Test func storage() {
        #expect(TTFormat.storage(382_000_000_000, style: .capacity) == "382 GB")
        #expect(TTFormat.storage(994_000_000_000, style: .capacity) == "994 GB")
        #expect(TTFormat.storage(2_000_000_000_000, style: .capacity) == "2 TB")
        #expect(TTFormat.storage(1_000_000_000_000, style: .capacity) == "1 TB")
        #expect(TTFormat.storage(1_240_000_000_000, style: .capacity) == "1.24 TB")
        #expect(TTFormat.storage(1_500_000_000_000, style: .capacity) == "1.5 TB")
        #expect(TTFormat.storage(48_200_000_000_000, style: .lifetime) == "48.2 TB")
        #expect(TTFormat.storage(3_820_000_000, style: .detail) == "3.82 GB")
        #expect(TTFormat.storage(840_000_000, style: .detail) == "840 MB")
        #expect(TTFormat.storage(15_100_000_000, style: .headline) == "15.1 GB")
    }

    // MARK: §5.4 Rates

    @Test func rates() {
        #expect(TTFormat.rate(0, units: bytes) == "0 KB/s")
        #expect(TTFormat.rateCell(0, units: bytes) == "—")
        #expect(TTFormat.rate(400, units: bytes) == "<1 KB/s")
        #expect(TTFormat.rate(12_000, units: bytes) == "12 KB/s")
        #expect(TTFormat.rate(840_000, units: bytes) == "840 KB/s")
        #expect(TTFormat.rate(100_000, units: bytes) == "100 KB/s")
        #expect(TTFormat.rate(8_100_000, units: bytes) == "8.1 MB/s")
        #expect(TTFormat.rate(12_400_000, units: bytes) == "12.4 MB/s")
        #expect(TTFormat.rate(38_000_000, units: bytes) == "38.0 MB/s")
        #expect(TTFormat.rate(142_000_000, units: bytes) == "142 MB/s")
        #expect(TTFormat.rate(1_050_000_000, units: bytes) == "1.05 GB/s")
        #expect(TTFormat.rate(999_700, units: bytes) == "1.0 MB/s") // promotes
        #expect(TTFormat.rate(99_970_000, units: bytes) == "100 MB/s")
        #expect(TTFormat.rate(-1, units: bytes) == "—")
    }

    @Test func bitRates() {
        #expect(TTFormat.rate(12_400_000, units: bits) == "99.2 Mbps")
        #expect(TTFormat.rate(105_000, units: bits) == "840 Kbps")
        #expect(TTFormat.rate(0, units: bits) == "0 Kbps")
        #expect(TTFormat.diskRate(12_400_000) == "12.4 MB/s")
        #expect(TTFormat.linkRate(1201) == "1,201 Mbps")
    }

    @Test func ratePairAndDirection() {
        #expect(TTFormat.ratePair(read: 142_000_000, write: 38_000_000) == "R 142 · W 38.0 MB/s")
        #expect(TTFormat.ratePair(read: 840_000, write: 38_000_000) == "R 840 KB/s · W 38.0 MB/s")
        #expect(TTFormat.rate(840_000, units: bytes, direction: .up) == "↑ 840 KB/s")
        #expect(TTFormat.rate(12_400_000, units: bytes, direction: .down) == "↓ 12.4 MB/s")
        #expect(TTFormat.iops(412) == "412")
        #expect(TTFormat.iops(3_400) == "3.4k")
        #expect(TTFormat.perSecond(0) == "0 / s")
    }

    // MARK: §5.5 Temperature

    @Test func temperature() {
        #expect(TTFormat.temperature(62, units: bytes) == "62°C")
        #expect(TTFormat.temperature(84.4, units: bytes) == "84°C")
        #expect(TTFormat.temperature(62, units: fahrenheit) == "144°F")
        #expect(TTFormat.temperatureCompact(62, units: bytes) == "62°")
        #expect(TTFormat.temperatureCompact(105, units: bytes) == "105°")
    }

    // MARK: §5.6 Power

    @Test func watts() {
        #expect(TTFormat.watts(18.6) == "18.6 W")
        #expect(TTFormat.watts(0.2) == "0.2 W")
        #expect(TTFormat.watts(96, digits: 0) == "96 W")
        #expect(TTFormat.appWatts(12.4) == "12.4 W")
        #expect(TTFormat.appWatts(7.15) == "7.15 W")
        #expect(TTFormat.appWatts(4.82) == "4.82 W")
        #expect(TTFormat.appWatts(0.35) == "0.35 W")
        #expect(TTFormat.appWatts(0.004) == "<0.01 W")
        #expect(TTFormat.appWatts(0) == "—")
        #expect(TTFormat.appWatts(nil) == "—")
        #expect(TTFormat.appWatts(9.996) == "10.0 W")
        #expect(TTFormat.wattHours(68.1, of: 72.4) == "68.1 of 72.4 Wh")
    }

    // MARK: §5.7 Frequency, rpm, misc

    @Test func misc() {
        #expect(TTFormat.frequency(1180) == "1,180 MHz")
        #expect(TTFormat.ghz(4120) == "4.12 GHz")
        #expect(TTFormat.ghz(2590) == "2.59 GHz")
        #expect(TTFormat.ghz(4120, digits: 1) == "4.1 GHz")
        #expect(TTFormat.rpm(2140) == "2,140 rpm")
        #expect(TTFormat.maxRPM(5700) == "max 5,700")
        #expect(TTFormat.count(3104) == "3,104")
        #expect(TTFormat.count(612) == "612")
        #expect(TTFormat.loadAverage([2.41, 2.1, 1.98]) == "2.41 · 2.10 · 1.98")
        #expect(TTFormat.latency(18.2) == "18 ms")
        #expect(TTFormat.latency(0.4) == "<1 ms")
        #expect(TTFormat.dBm(-52) == "−52 dBm")
        #expect(TTFormat.compressionRatio(2.34) == "2.3 : 1")
    }

    // MARK: §5.8 Durations

    @Test func durations() {
        #expect(TTFormat.duration(.seconds(5 * 3600 + 40 * 60 + 30)) == "5 h 40 m")
        #expect(TTFormat.duration(.seconds(4 * 86400 + 7 * 3600 + 12 * 60)) == "4 d 7 h")
        #expect(TTFormat.duration(.seconds(12 * 60)) == "12 m")
        #expect(TTFormat.duration(.seconds(30)) == "<1 m")
        #expect(TTFormat.duration(.seconds(5 * 3600)) == "5 h")
        #expect(TTFormat.cpuTime(52_000_000_000) == "0:52")
        #expect(TTFormat.cpuTime(UInt64(58 * 60 + 12) * 1_000_000_000) == "58:12")
        #expect(TTFormat.cpuTime(UInt64(2 * 3600 + 41 * 60 + 7) * 1_000_000_000) == "2:41:07")
        #expect(TTFormat.cpuTime(UInt64(123 * 3600) * 1_000_000_000) == "123:00:00")
    }

    // MARK: §5.10 Nice ceilings

    @Test func niceCeiling() {
        #expect(TTFormat.niceCeiling(0.3, minimum: 1) == 1)
        #expect(TTFormat.niceCeiling(3.2) == 4)
        #expect(TTFormat.niceCeiling(4.5) == 5)
        #expect(TTFormat.niceCeiling(38) == 40)
        #expect(TTFormat.niceCeiling(41) == 50)
        #expect(TTFormat.niceCeiling(520) == 1000)
        #expect(TTFormat.niceCeiling(200) == 200)
        #expect(TTFormat.niceRateCeiling(38_000_000) == 40_000_000)
        #expect(TTFormat.niceRateCeiling(10_000) == 1_000_000)
        #expect(TTFormat.rateScale(40_000_000, units: bytes) == "40 MB/s")
        #expect(TTFormat.rateScale(2_000_000_000, units: bytes) == "2 GB/s")
    }
}
