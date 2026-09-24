import CoreWLAN
import Foundation
import Testing
@testable import MonitorModel
@testable import MonitorSensors

@Suite struct WiFiParseTests {
    static let assoc = WiFiFields(interface: "en0", powerOn: true, rssi: -63, noise: -89, txRateMbps: 390, channel: 52,
                                  band: 2, width: 3, phy: 5)

    @Test func mapsAssociatedLink() {
        #expect(WiFiParse.reading(Self.assoc) == WiFiInfo(interface: "en0", standardLabel: "Wi-Fi 5 (802.11ac)", bandGHz: 5,
                                                          channel: 52, channelWidthMHz: 80, rssi: -63, noise: -89, txRateMbps: 390))
    }

    @Test func notAssociatedOrOffIsUnknownNotZero() {
        var f = Self.assoc
        f.rssi = 0
        f.noise = 0
        f.txRateMbps = 0
        f.channel = nil
        f.band = 0
        f.width = 0
        f.phy = 0
        #expect(WiFiParse.reading(f) == WiFiInfo(interface: "en0"))
        var off = Self.assoc
        off.powerOn = false
        #expect(WiFiParse.reading(off) == WiFiInfo(interface: "en0"))
    }

    @Test func standardsBandsWidths() {
        #expect(WiFiParse.standard(phy: 6, band: 3) == "Wi-Fi 6E (802.11ax)")
        #expect(WiFiParse.standard(phy: 6, band: 2) == "Wi-Fi 6 (802.11ax)")
        #expect(WiFiParse.standard(phy: 7, band: 3) == "Wi-Fi 7 (802.11be)")
        #expect(WiFiParse.standard(phy: 99, band: 1) == nil)
        #expect([0, 1, 2, 3, 4].map(WiFiParse.bandGHz) == [nil, 2.4, 5, 6, nil])
        #expect([0, 1, 2, 3, 4, 5].map(WiFiParse.widthMHz) == [nil, 20, 40, 80, 160, nil])
    }

    @Test func capturedFields() throws {
        let f = try JSONDecoder().decode(WiFiFields.self, from: W6cFixture.data("wifi_fields.json"))
        let r = WiFiParse.reading(f)
        #expect(r.interface.hasPrefix("en"))
        if f.powerOn, f.rssi < 0 {
            #expect(r.rssi == f.rssi && r.channel != nil && r.bandGHz != nil && r.standardLabel != nil)
        }
    }
}

/// `TELLTALE_HW_TESTS=1 scripts/test.sh WiFiSmokeTests` (capture: `TELLTALE_CAPTURE=1`).
@Suite(.enabled(if: W6cFixture.hardwareTests), .serialized)
struct WiFiSmokeTests {
    /// `system_profiler SPAirPortDataType` "Current Network Information" of the first interface.
    static func profiler() throws -> (phy: String?, channel: Int?, band: Double?, width: Int?, rssi: Int?, noise: Int?, rate: Double?) {
        let text = try W6cFixture.run(["/usr/sbin/system_profiler", "SPAirPortDataType"])
        guard let cur = text.range(of: "Current Network Information:") else { return (nil, nil, nil, nil, nil, nil, nil) }
        let block = text[cur.upperBound...].prefix(1_200)
        func value(_ key: String) -> String? {
            block.split(separator: "\n").first { $0.contains(key + ":") }?
                .split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        func ints(_ s: String?) -> [Int] {
            (s ?? "").split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
        }
        let ch = value("Channel") // "52 (5GHz, 80MHz)"
        let chNums = ints(ch)
        let band: Double? = ch.map { $0.contains("2GHz") ? 2.4 : $0.contains("6GHz") ? 6 : $0.contains("5GHz") ? 5 : 0 }
        let sn = ints(value("Signal / Noise"))
        return (value("PHY Mode"), chNums.first, band, chNums.count >= 3 ? chNums[2] : nil,
                sn.first, sn.count > 1 ? sn[1] : nil, value("Transmit Rate").flatMap(Double.init))
    }

    @Test func captureFixtures() throws {
        guard W6cFixture.capture else { return }
        let i = try #require(CWWiFiClient.shared().interface())
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: W6cFixture.sourceURL(""), withIntermediateDirectories: true)
        try enc.encode(WiFiBox.fields(i)).write(to: W6cFixture.sourceURL("wifi_fields.json"))
    }

    @Test func matchesSystemProfiler() throws {
        let s = WiFiSensor()
        let t0 = W6cClock.uptimeNs()
        try s.prepare()
        let prepMs = W6cFixture.ms(W6cClock.uptimeNs() - t0)
        let first = try s.sample(SampleContext(demand: .wifi))
        let r = first.reading
        let p = try Self.profiler()
        var ms: [Double] = []
        var readMs: [Double] = []
        var captured = first.capturedNs
        for _ in 0..<30 {
            let t = W6cClock.uptimeNs()
            let x = try s.sample(SampleContext(demand: .wifi))
            ms.append(W6cFixture.ms(W6cClock.uptimeNs() - t))
            #expect(x.capturedNs >= captured) // last completed read, never older
            captured = x.capturedNs
            usleep(30_000)
            readMs.append(W6cFixture.ms(s.box.lastReadCostNs))
        }
        #expect(s.cadence.requires == .wifi)
        print("W6c wifi: \(r)")
        print("W6c wifi profiler: \(p)")
        print(String(format: "W6c wifi bench: prepare %.1f ms; sample() p50 %.3f p95 %.3f ms; off-queue read p50 %.2f p95 %.2f ms",
                     prepMs, W6cFixture.percentile(ms, 0.5), W6cFixture.percentile(ms, 0.95),
                     W6cFixture.percentile(readMs, 0.5), W6cFixture.percentile(readMs, 0.95)))
        guard p.channel != nil else {
            #expect(r.rssi == nil) // not associated
            return
        }
        #expect(r.channel == p.channel)
        #expect(r.bandGHz == p.band)
        #expect(r.channelWidthMHz == p.width)
        if let phy = p.phy { #expect(r.standardLabel?.contains(phy) == true) }
        #expect(abs((r.rssi ?? 0) - (p.rssi ?? 0)) <= 10)
        #expect(abs((r.noise ?? 0) - (p.noise ?? 0)) <= 10)
        if let rate = p.rate, let ours = r.txRateMbps { #expect(abs(ours - rate) <= 0.5 * rate) }
    }
}
