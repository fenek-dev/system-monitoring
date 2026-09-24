import CoreWLAN
import MonitorModel

/// Raw CoreWLAN values (enum raw values, so the mapping is testable without CoreWLAN objects).
struct WiFiFields: Sendable, Equatable, Codable {
    var interface: String
    var powerOn: Bool
    var rssi: Int
    var noise: Int
    var txRateMbps: Double
    var channel: Int?
    /// `CWChannelBand` raw: 0 unknown, 1 = 2.4 GHz, 2 = 5 GHz, 3 = 6 GHz.
    var band: Int
    /// `CWChannelWidth` raw: 0 unknown, 1 = 20, 2 = 40, 3 = 80, 4 = 160 MHz.
    var width: Int
    /// `CWPHYMode` raw: 0 none, 1 a, 2 b, 3 g, 4 n, 5 ac, 6 ax, 7 be.
    var phy: Int
}

enum WiFiParse {
    static func reading(_ f: WiFiFields) -> WiFiInfo {
        // Powered off or not associated: CoreWLAN reports 0 for rssi/noise/rate — unknown, not zero.
        guard f.powerOn else { return WiFiInfo(interface: f.interface) }
        let band = bandGHz(f.band)
        return WiFiInfo(
            interface: f.interface,
            standardLabel: standard(phy: f.phy, band: f.band),
            bandGHz: band,
            channel: f.channel.flatMap { $0 > 0 ? $0 : nil },
            channelWidthMHz: widthMHz(f.width),
            rssi: f.rssi < 0 ? f.rssi : nil,
            noise: f.noise < 0 ? f.noise : nil,
            txRateMbps: f.txRateMbps > 0 ? f.txRateMbps : nil
        )
    }

    static func bandGHz(_ raw: Int) -> Double? {
        switch raw {
        case 1: 2.4
        case 2: 5
        case 3: 6
        default: nil
        }
    }

    static func widthMHz(_ raw: Int) -> Int? {
        switch raw {
        case 1: 20
        case 2: 40
        case 3: 80
        case 4: 160
        default: nil
        }
    }

    static func standard(phy: Int, band: Int) -> String? {
        switch phy {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "Wi-Fi 4 (802.11n)"
        case 5: "Wi-Fi 5 (802.11ac)"
        case 6: band == 3 ? "Wi-Fi 6E (802.11ax)" : "Wi-Fi 6 (802.11ax)"
        case 7: "Wi-Fi 7 (802.11be)"
        default: nil
        }
    }
}

/// Wi-Fi link via CoreWLAN: RSSI, noise, channel, band, width, PHY mode, tx rate. No SSID: it needs Location
/// permission (CoreWLAN and SCDynamicStore both redact it; docs/findings/extras.md §5).
public final class WiFiSensor: Sensor {
    public typealias Reading = WiFiInfo
    public let id: SensorID = .wifi
    public let cadence: SensorCadence = .every(.seconds(2), background: .seconds(30))

    private var iface: CWInterface?

    public init() {}

    /// First CoreWLAN call costs ~40 ms (XPC connection); later ones ~ms.
    public func prepare() throws(SensorError) {
        guard iface == nil else { return }
        guard let i = CWWiFiClient.shared().interface() else { throw .unavailable("No Wi-Fi interface") }
        iface = i
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: WiFiInfo, capturedNs: UInt64) {
        (WiFiParse.reading(try fields()), W6cClock.uptimeNs())
    }

    func fields() throws(SensorError) -> WiFiFields {
        guard let i = iface else { throw .unavailable("Wi-Fi not prepared") }
        let ch = i.wlanChannel()
        return WiFiFields(
            interface: i.interfaceName ?? "",
            powerOn: i.powerOn(),
            rssi: i.rssiValue(),
            noise: i.noiseMeasurement(),
            txRateMbps: i.transmitRate(),
            channel: ch?.channelNumber,
            band: ch?.channelBand.rawValue ?? 0,
            width: ch?.channelWidth.rawValue ?? 0,
            phy: i.activePHYMode().rawValue
        )
    }

    public func invalidate() {
        iface = nil
    }
}
