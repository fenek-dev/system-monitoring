import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

/// SMCDecoder with the byte patterns from docs/findings/smc.md (M1 Max, macOS 26.5).
/// Battery/charger (`B<digit>…`, `CH…`) integers are LITTLE-endian; fan/temp/other integers are big-endian;
/// `flt ` is always little-endian.
struct SMCParseTests {
    private func d(_ key: String, _ type: String, _ bytes: [UInt8]) -> Double? {
        SMCDecoder.decode(key: key, type: type, bytes: bytes)
    }

    @Test func batteryIntegersAreLittleEndian() {
        #expect(d("B0CT", "ui16", [0x3F, 0x07]) == 1855)          // CycleCount (BE would be 16135)
        #expect(d("B0DC", "ui16", [0xBB, 0x17]) == 6075)          // DesignCapacity (BE 47895)
        #expect(d("B0FC", "ui16", [0x35, 0x11]) == 4405)          // AppleRawMaxCapacity
        #expect(d("CHBV", "ui32", [0x76, 0x10, 0x00, 0x00]) == 4214)   // ChargingVoltage mV (BE ≈ 1.98e9)
        #expect(d("B0AC", "si16", [0xBD, 0xF7]) == -2115)         // discharge current mA
        #expect(d("B0TF", "ui16", [0xFF, 0xFF]) == 65535)          // "N/A" sentinel passes through
    }

    @Test func fanFloatsAreLittleEndian() {
        #expect(d("F0Mx", "flt ", [0x00, 0x98, 0xB4, 0x45]) == 5779)
        let bits = Float(2309.5).bitPattern
        let le = [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        #expect(d("F0Ac", "flt ", le) == 2309.5)
        #expect(d("PSTR", "flt ", [0x00, 0x00, 0xC8, 0x41]) == 25)   // system watts
    }

    @Test func otherIntegersAreBigEndian() {
        #expect(d("FNum", "ui8 ", [0x02]) == 2)
        #expect(d("#KEY", "ui32", [0x00, 0x00, 0x08, 0x49]) == 2121)
        #expect(d("TC0P", "sp78", [0x1A, 0x80]) == 26.5)
        #expect(d("TC0P", "sp78", [0xFF, 0x00]) == -1)
        #expect(d("F0Ac", "fpe2", [0x24, 0x10]) == 2308)          // Intel-era fan RPM (unsigned 14.2)
        #expect(d("XXXX", "si16", [0xFF, 0xFE]) == -2)
        #expect(d("XXXX", "ui16", [0x01, 0x00]) == 256)
        #expect(d("XXXX", "flag", [0x01]) == 1)
    }

    @Test func invalidInputIsNil() {
        #expect(d("F0Ac", "flt ", [0x00, 0x00, 0xC0, 0x7F]) == nil)   // NaN
        #expect(d("F0Ac", "flt ", [0x00, 0x00, 0x80, 0x7F]) == nil)   // +inf
        #expect(d("F0Ac", "flt ", [0x00, 0x00]) == nil)               // short
        #expect(d("B0CT", "ui16", [0x3F]) == nil)
        #expect(d("XXXX", "ch8*", [0x41, 0x42]) == nil)               // not numeric
        #expect(d("XXXX", "", []) == nil)
    }

    @Test func byteOrderByFamily() {
        #expect(SMCDecoder.integerByteOrder(forKey: "B0CT") == .little)
        #expect(SMCDecoder.integerByteOrder(forKey: "B1AV") == .little)
        #expect(SMCDecoder.integerByteOrder(forKey: "CHLC") == .little)
        #expect(SMCDecoder.integerByteOrder(forKey: "BNum") == .big)     // not B<digit>
        #expect(SMCDecoder.integerByteOrder(forKey: "TB0T") == .big)
        #expect(SMCDecoder.integerByteOrder(forKey: "FNum") == .big)
    }

    @Test func fourCCRoundTrip() {
        #expect(SMCDecoder.fourCC(0x666C_7420) == "flt ")
        #expect(SMCDecoder.fourCC(0x7569_3136) == "ui16")
        #expect(SMCDecoder.fourCC(0) == "")
    }

    /// ICR-6: `catalogMatched` round-trips and defaults to false for readings recorded before the field existed.
    @Test func readingCatalogMatchedCodable() throws {
        let old = #"{"fans":[],"temperatures":[],"systemWatts":20}"#
        let r = try JSONDecoder().decode(SMCReading.self, from: Data(old.utf8))
        #expect(r.catalogMatched == false && r.systemWatts == 20 && r.adapterWatts == nil)
        let again = try JSONDecoder().decode(SMCReading.self, from: JSONEncoder().encode(SMCReading(catalogMatched: true)))
        #expect(again.catalogMatched)
    }

    @Test func plausibleTemperatures() {
        #expect(SMCDecoder.isPlausibleTemperature(45))
        #expect(!SMCDecoder.isPlausibleTemperature(0))
        #expect(!SMCDecoder.isPlausibleTemperature(-40))
        #expect(!SMCDecoder.isPlausibleTemperature(150))
        #expect(!SMCDecoder.isPlausibleTemperature(.nan))
    }
}
