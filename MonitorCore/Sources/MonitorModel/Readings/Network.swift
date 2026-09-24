import Foundation

public enum TransportProtocol: String, Sendable, Codable { case tcp, udp, quic, other }

public struct ByteCounts: Sendable, Codable, Hashable {
    public var rx, tx: UInt64

    public init(rx: UInt64 = 0, tx: UInt64 = 0) {
        self.rx = rx
        self.tx = tx
    }
}

public struct FlowCounter: Sendable, Codable, Hashable {
    public var flowID: UInt64
    public var process: ProcessID, effectivePID: Int32?
    public var proto: TransportProtocol
    /// Cumulative for the flow.
    public var rxBytes, txBytes: UInt64
    /// Only with `.connections`.
    public var localPort: UInt16?, remoteAddress: String?, remotePort: UInt16?
    public var tcpState: String?, interface: String?

    public init(
        flowID: UInt64 = 0,
        process: ProcessID = ProcessID(),
        effectivePID: Int32? = nil,
        proto: TransportProtocol = .other,
        rxBytes: UInt64 = 0,
        txBytes: UInt64 = 0,
        localPort: UInt16? = nil,
        remoteAddress: String? = nil,
        remotePort: UInt16? = nil,
        tcpState: String? = nil,
        interface: String? = nil
    ) {
        self.flowID = flowID
        self.process = process
        self.effectivePID = effectivePID
        self.proto = proto
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.tcpState = tcpState
        self.interface = interface
    }
}

public struct NetworkFlowsReading: Sendable, Codable {
    public var flows: [FlowCounter]
    /// Cumulative bytes of removed flows **since sensor start**, per process; entries pruned 10 min after the process exits.
    public var closedBytes: [ProcessID: ByteCounts]
    /// Cumulative bytes of sources retired before their pid could be resolved → assembled into AppKey.system.
    public var unattributedBytes: ByteCounts

    public init(
        flows: [FlowCounter] = [],
        closedBytes: [ProcessID: ByteCounts] = [:],
        unattributedBytes: ByteCounts = ByteCounts()
    ) {
        self.flows = flows
        self.closedBytes = closedBytes
        self.unattributedBytes = unattributedBytes
    }
}

public enum InterfaceKind: String, Sendable, Codable { case wifi, ethernet, thunderbolt, cellular, other }

public struct InterfaceCounter: Sendable, Codable, Hashable {
    public var bsdName: String, displayName: String, kind: InterfaceKind, isUp: Bool, isPrimary: Bool
    public var rxBytes, txBytes: UInt64, ipv4: String?, linkRateBps: Double?

    public init(
        bsdName: String = "",
        displayName: String = "",
        kind: InterfaceKind = .other,
        isUp: Bool = false,
        isPrimary: Bool = false,
        rxBytes: UInt64 = 0,
        txBytes: UInt64 = 0,
        ipv4: String? = nil,
        linkRateBps: Double? = nil
    ) {
        self.bsdName = bsdName
        self.displayName = displayName
        self.kind = kind
        self.isUp = isUp
        self.isPrimary = isPrimary
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.ipv4 = ipv4
        self.linkRateBps = linkRateBps
    }
}

public struct InterfacesReading: Sendable, Codable {
    public var interfaces: [InterfaceCounter]
    public var routerIPv4: String?

    public init(interfaces: [InterfaceCounter] = [], routerIPv4: String? = nil) {
        self.interfaces = interfaces
        self.routerIPv4 = routerIPv4
    }
}

/// No SSID (ruling).
public struct WiFiInfo: Sendable, Codable, Equatable {
    public var interface: String, standardLabel: String?, bandGHz: Double?, channel: Int?, channelWidthMHz: Int?
    public var rssi: Int?, noise: Int?, txRateMbps: Double?

    public init(
        interface: String = "",
        standardLabel: String? = nil,
        bandGHz: Double? = nil,
        channel: Int? = nil,
        channelWidthMHz: Int? = nil,
        rssi: Int? = nil,
        noise: Int? = nil,
        txRateMbps: Double? = nil
    ) {
        self.interface = interface
        self.standardLabel = standardLabel
        self.bandGHz = bandGHz
        self.channel = channel
        self.channelWidthMHz = channelWidthMHz
        self.rssi = rssi
        self.noise = noise
        self.txRateMbps = txRateMbps
    }
}

public struct LatencyReading: Sendable, Codable, Equatable {
    public var target: String, lastRTTms: Double?, minMs: Double?, avgMs: Double?, maxMs: Double?, lossFraction5m: Double?

    public init(
        target: String = "",
        lastRTTms: Double? = nil,
        minMs: Double? = nil,
        avgMs: Double? = nil,
        maxMs: Double? = nil,
        lossFraction5m: Double? = nil
    ) {
        self.target = target
        self.lastRTTms = lastRTTms
        self.minMs = minMs
        self.avgMs = avgMs
        self.maxMs = maxMs
        self.lossFraction5m = lossFraction5m
    }
}
