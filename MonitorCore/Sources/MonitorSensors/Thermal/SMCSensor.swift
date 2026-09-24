import CPrivate
import Foundation
import IOKit
import MonitorModel

/// Fans, catalog T-keys and PSTR/PDTR from AppleSMC (docs/findings/smc.md, temps.md).
/// `prepare()` opens the connection and resolves only hard-coded keys (1 key-info call each); every read is then
/// one round trip with the cached size. The full key sweep runs once off-queue (`SMCKeySweep`) and feeds the raw
/// list (`.rawTemperatures`) and, for unknown models, the generic catalog families.
public final class SMCSensor: Sensor {
    public typealias Reading = SMCReading
    public let id: SensorID = .smc
    /// Measured (M1 Max): ~5–8 ms per sample for 36 keys; 10 s in background (see W6b report).
    public let cadence: SensorCadence = .every(.seconds(2), background: .seconds(10))

    struct Key: Sendable, Equatable {
        var name: String
        var type: String
        var size: UInt32
    }

    struct Fan: Sendable {
        var index: Int
        var actual: Key?
        var minRPM: Double
        var maxRPM: Double
    }

    let sweep: SMCKeySweep
    private let hwModel: String
    private var conn: io_connect_t = 0
    private var catalog: TemperatureCatalog?
    private var model: TemperatureCatalog.Model?
    private var fans: [Fan] = []
    private var systemPower: Key?
    private var adapterPower: Key?
    private var temperatureKeys: [(key: Key, group: TemperatureGroup)] = []
    private var genericResolved = false
    private var scratch = [UInt8](repeating: 0, count: 32)

    public convenience init() { self.init(hwModel: w6bHWModel, osBuild: w6bOSBuild) }

    init(hwModel: String, osBuild: String, cacheDirectory: URL? = nil) {
        self.hwModel = hwModel
        sweep = SMCKeySweep(hwModel: hwModel, osBuild: osBuild, cacheDirectory: cacheDirectory)
    }

    deinit { if conn != 0 { smc_close(conn) } }

    /// True when the catalog has an entry for this model (→ `SMCReading.catalogMatched`, ICR-6).
    var catalogMatched: Bool { model != nil }

    public func prepare() throws(SensorError) {
        guard conn == 0 else { return }
        guard tt_smc_available() else { throw .unavailable("SMC unavailable") }
        let c = smc_open()
        guard c != 0 else { throw .unavailable("AppleSMC: open failed") }
        conn = c
        catalog = try? TemperatureCatalog.bundled()
        model = catalog?.model(for: hwModel)

        let fanCount = Int(readRaw("FNum") ?? 0)
        fans = (0..<min(max(fanCount, 0), 8)).map { i in
            Fan(index: i, actual: info("F\(i)Ac"), minRPM: readRaw("F\(i)Mn") ?? 0, maxRPM: readRaw("F\(i)Mx") ?? 0)
        }
        systemPower = info("PSTR")
        adapterPower = info("PDTR")
        temperatureKeys = (model?.smc ?? [:]).sorted { $0.key < $1.key }.compactMap { k, g in info(k).map { ($0, g) } }
        genericResolved = model != nil
        sweep.start()
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: SMCReading, capturedNs: UInt64) {
        if conn == 0 { try prepare() }
        resolveGenericIfReady()
        var r = SMCReading(catalogMatched: model != nil)
        var reads = 0, failures = 0
        func value(_ k: Key?) -> Double? {
            guard let k else { return nil }
            reads += 1
            let v = read(k)
            if v == nil { failures += 1 }
            return v
        }
        r.fans = fans.map { f in
            RawFan(index: f.index, rpm: max(0, value(f.actual) ?? 0), minRPM: f.minRPM, maxRPM: f.maxRPM)
        }
        r.systemWatts = value(systemPower)
        r.adapterWatts = value(adapterPower)
        r.temperatures.reserveCapacity(temperatureKeys.count)
        for (k, g) in temperatureKeys {
            if let c = value(k), SMCDecoder.isPlausibleTemperature(c) {
                r.temperatures.append(RawTemperature(name: k.name, celsius: c, group: g, source: .smc))
            }
        }
        if ctx.demand.contains(.rawTemperatures), let all = sweep.keys {
            let mapped = Set(temperatureKeys.map(\.key.name))
            for e in all where !mapped.contains(e.key) {
                if let c = value(Key(name: e.key, type: e.type, size: e.size)), SMCDecoder.isPlausibleTemperature(c) {
                    r.temperatures.append(RawTemperature(name: e.key, celsius: c, group: .other, source: .smc))
                }
            }
        }
        if reads > 0 && failures == reads { throw .transient("SMC: all \(reads) reads failed") }
        return (r, w6bUptimeNs())
    }

    public func invalidate() {
        if conn != 0 { smc_close(conn) }
        conn = 0
        fans = []
        temperatureKeys = []
        genericResolved = false
    }

    // MARK: - FFI helpers

    /// Unknown model: map sweep keys through the generic families once the sweep is available.
    private func resolveGenericIfReady() {
        guard !genericResolved, let catalog, let keys = sweep.keys else { return }
        temperatureKeys = keys.compactMap { e in
            catalog.smcGroup(e.key, model: nil).map { (Key(name: e.key, type: e.type, size: e.size), $0) }
        }
        genericResolved = true
    }

    private func info(_ name: String) -> Key? {
        var type: UInt32 = 0, size: UInt32 = 0
        guard smc_key_info(conn, name, &type, &size) == 0, size > 0, size <= 32 else { return nil }
        return Key(name: name, type: SMCDecoder.fourCC(type), size: size)
    }

    private func read(_ k: Key) -> Double? {
        let ok = scratch.withUnsafeMutableBufferPointer { smc_read_sized(conn, k.name, k.size, $0.baseAddress) == 0 }
        guard ok else { return nil }
        return SMCDecoder.decode(key: k.name, type: k.type, bytes: Array(scratch.prefix(Int(k.size))))
    }

    /// Two-round-trip read for one-off keys in prepare.
    private func readRaw(_ name: String) -> Double? {
        info(name).flatMap(read)
    }
}
