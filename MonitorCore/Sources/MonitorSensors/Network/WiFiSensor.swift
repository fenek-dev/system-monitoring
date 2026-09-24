import CoreWLAN
import Dispatch
import MonitorModel
import os

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
///
/// Only sampled while `.wifi` is demanded (the Network page). Each CWInterface getter is an XPC round trip to
/// airportd (~6 ms per read in total), so reads run on the box queue: `sample()` returns the last completed read
/// with its capturedNs and starts the next one; an airportd stall never blocks a tick.
public final class WiFiSensor: Sensor {
    public typealias Reading = WiFiInfo
    public let id: SensorID = .wifi
    public let cadence: SensorCadence = .every(.seconds(2), background: .seconds(30), requires: .wifi)

    let box: WiFiBox

    public convenience init() { self.init(box: WiFiBox()) }

    /// Tests inject a fake read (`WiFiBox(read:)`).
    init(box: WiFiBox) { self.box = box }

    /// No CoreWLAN call on the sampler (S-M6): the interface check is the box's first read (off-queue, awaited ≤ 200 ms
    /// by the first sample); "no interface" surfaces there as `.unavailable`.
    public func prepare() throws(SensorError) {
        guard !box.isPrepared else { return }
        box.setPrepared(true)
        box.startRead()
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: WiFiInfo, capturedNs: UInt64) {
        guard box.isPrepared else { throw .unavailable("Wi-Fi not prepared") }
        // S-M5: a read hung past its deadline (airportd XPC) → stale data is not served as fresh (slot → degraded).
        if box.isStalled(nowNs: W6cClock.uptimeNs()) { throw .timeout }
        if let last = box.last() {
            box.startRead()
            return try last.get()
        }
        // First sample: the read started in prepare(); give it ≤ 200 ms.
        box.startRead()
        guard let last = box.awaitFirst(timeoutMs: 200) else { throw .transient("Wi-Fi: first read pending") }
        return try last.get()
    }

    public func invalidate() {
        box.setPrepared(false)
    }
}

/// Off-queue CoreWLAN reads (ARCHITECTURE §4 box pattern; the CWInterface never leaves the queue's closure).
final class WiFiBox: Sendable {
    struct State: Sendable {
        var prepared = false
        var inFlight = false
        var last: Result<(reading: WiFiInfo, capturedNs: UInt64), SensorError>?
        var lastReadCostNs: UInt64 = 0
        var firstSignalled = false
        /// Uptime the in-flight read started.
        var readStartedNs: UInt64 = 0
    }

    /// A read (~6 ms) still running after this is hung.
    static let readDeadlineNs: UInt64 = 10_000_000_000

    let queue = DispatchQueue(label: "dev.telltale.wifi", qos: .utility)
    let lock = OSAllocatedUnfairLock(initialState: State())
    let firstRead = DispatchSemaphore(value: 0)
    /// Blocking read (runs on `queue` only). Injectable for tests.
    let read: @Sendable () -> Result<WiFiFields, SensorError>

    init(read: @escaping @Sendable () -> Result<WiFiFields, SensorError> = WiFiBox.coreWLANRead) {
        self.read = read
    }

    @Sendable static func coreWLANRead() -> Result<WiFiFields, SensorError> {
        guard let i = CWWiFiClient.shared().interface() else { return .failure(.unavailable("No Wi-Fi interface")) }
        return .success(fields(i))
    }

    /// Waits ≤ `timeoutMs` for this prepare cycle's first read.
    func awaitFirst(timeoutMs: Int) -> Result<(reading: WiFiInfo, capturedNs: UInt64), SensorError>? {
        if let l = last() { return l }
        _ = firstRead.wait(timeout: .now() + .milliseconds(timeoutMs))
        return last()
    }

    var isPrepared: Bool { lock.withLock { $0.prepared } }
    var lastReadCostNs: UInt64 { lock.withLock { $0.lastReadCostNs } }

    /// Preparing re-arms the first-read signal (each invalidate → prepare cycle waits for its own first read, and a
    /// stale unconsumed signal from an earlier cycle can't satisfy that wait early).
    func setPrepared(_ p: Bool) {
        if p { while firstRead.wait(timeout: .now()) == .success {} }
        lock.withLock { s in
            s.prepared = p
            s.last = nil
            if p { s.firstSignalled = false }
        }
    }

    func last() -> Result<(reading: WiFiInfo, capturedNs: UInt64), SensorError>? {
        lock.withLock { $0.last }
    }

    /// The in-flight read has run past `readDeadlineNs` (a hung read is never doubled up: `startRead` waits for it).
    func isStalled(nowNs: UInt64) -> Bool {
        lock.withLock { s in s.inFlight && nowNs >= s.readStartedNs && nowNs - s.readStartedNs > Self.readDeadlineNs }
    }

    func startRead(nowNs: UInt64 = W6cClock.uptimeNs()) {
        let go = lock.withLock { s -> Bool in
            guard s.prepared, !s.inFlight else { return false }
            s.inFlight = true
            s.readStartedNs = nowNs
            return true
        }
        guard go else { return }
        queue.async { [self] in
            let t0 = W6cClock.uptimeNs()
            let result = read()
            let now = W6cClock.uptimeNs()
            let signal = lock.withLock { s -> Bool in
                s.inFlight = false
                guard s.prepared else { return false }
                s.last = result.map { (WiFiParse.reading($0), now) }
                s.lastReadCostNs = now >= t0 ? now - t0 : 0
                defer { s.firstSignalled = true }
                return !s.firstSignalled
            }
            if signal { firstRead.signal() }
        }
    }

    static func fields(_ i: CWInterface) -> WiFiFields {
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
}
