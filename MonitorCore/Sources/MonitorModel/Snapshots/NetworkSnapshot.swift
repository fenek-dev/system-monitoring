import Foundation

public struct InterfaceSnapshot: Sendable, Codable, Hashable, Identifiable {
    public var id: String { bsdName }
    public var bsdName: String, displayName: String, kind: InterfaceKind, isUp: Bool, isPrimary: Bool
    public var rxBps: Double?, txBps: Double?, ipv4: String?, linkRateBps: Double?

    public init(
        bsdName: String = "",
        displayName: String = "",
        kind: InterfaceKind = .other,
        isUp: Bool = false,
        isPrimary: Bool = false,
        rxBps: Double? = nil,
        txBps: Double? = nil,
        ipv4: String? = nil,
        linkRateBps: Double? = nil
    ) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.kind = kind
        self.isUp = isUp
        self.isPrimary = isPrimary
        self.rxBps = rxBps
        self.txBps = txBps
        self.ipv4 = ipv4
        self.linkRateBps = linkRateBps
    }
}

public struct NetworkSnapshot: Sendable, Codable, Equatable {
    public var rxBps: Double?, txBps: Double?, interfaces: [InterfaceSnapshot]
    public var wifi: WiFiInfo?, routerIPv4: String?, localIPv4: String?, latency: LatencyReading?

    public init(
        rxBps: Double? = nil,
        txBps: Double? = nil,
        interfaces: [InterfaceSnapshot] = [],
        wifi: WiFiInfo? = nil,
        routerIPv4: String? = nil,
        localIPv4: String? = nil,
        latency: LatencyReading? = nil
    ) {
        self.rxBps = rxBps
        self.txBps = txBps
        self.interfaces = interfaces
        self.wifi = wifi
        self.routerIPv4 = routerIPv4
        self.localIPv4 = localIPv4
        self.latency = latency
    }
}
