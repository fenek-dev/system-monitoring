import MonitorModel
import SystemConfiguration

/// Interface byte counters (64-bit, IFMIB; enumeration via `NET_RT_IFLIST2`), kinds and names (SystemConfiguration), primary interface
/// and router. Counters every tick (one sysctl into a retained buffer); the slow part (SC interface list,
/// primary, default route) refreshes every 10 s or when the interface set changes.
public final class InterfaceSensor: Sensor {
    public typealias Reading = InterfacesReading
    public let id: SensorID = .interfaces
    public let cadence: SensorCadence = .everyTick

    static let slowRefreshNs: UInt64 = 10_000_000_000

    private var store: SCDynamicStore?
    private var buffer: [UInt8] = []
    private var descriptors: [String: InterfaceDescriptor] = [:]
    private var primary: String?
    private var router: String?
    private var knownIndexes: [UInt16] = []
    private var lastSlowNs: UInt64?

    public init() {}

    public func prepare() throws(SensorError) {
        if store == nil { store = NetworkFFI.makeStore("dev.telltale.interfaces") }
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: InterfacesReading, capturedNs: UInt64) {
        let raw = try NetworkFFI.interfaces(&buffer)
        let now = W6cClock.uptimeNs()
        let indexes = raw.map(\.index)
        if indexes != knownIndexes || lastSlowNs.map({ now < $0 || now - $0 >= Self.slowRefreshNs }) ?? true {
            refreshSlow()
            knownIndexes = indexes
            lastSlowNs = now
        }
        // IFLIST2 enumerates (names, flags, IPv4); its byte counters are 32-bit-truncated, so the reported
        // interfaces get their 64-bit counters from IFMIB (one small sysctl each).
        var rows = InterfaceParse.included(raw, descriptors: descriptors, primary: primary)
        NetworkFFI.overlay64BitCounters(&rows)
        return (InterfaceParse.reading(rows, descriptors: descriptors, primary: primary, router: router), now)
    }

    public func invalidate() {
        store = nil
        lastSlowNs = nil
        knownIndexes = []
    }

    private func refreshSlow() {
        descriptors = NetworkFFI.descriptors()
        let g = NetworkFFI.globalIPv4(store)
        primary = g.primary
        router = NetworkFFI.router(primary: g.primary, scRouter: g.router)
    }
}
