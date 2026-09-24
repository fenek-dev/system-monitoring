import Foundation

public struct ConnectionSample: Sendable, Codable, Hashable, Identifiable {
    public var id: UInt64
    public var process: ProcessID, app: AppKey, proto: TransportProtocol
    public var localPort: UInt16?, remoteAddress: String?, remotePort: UInt16?, remoteHost: String?
    public var tcpState: String?, rxBps: Double?, txBps: Double?, rxTotal: UInt64, txTotal: UInt64

    public init(
        id: UInt64 = 0,
        process: ProcessID = ProcessID(),
        app: AppKey = .system,
        proto: TransportProtocol = .other,
        localPort: UInt16? = nil,
        remoteAddress: String? = nil,
        remotePort: UInt16? = nil,
        remoteHost: String? = nil,
        tcpState: String? = nil,
        rxBps: Double? = nil,
        txBps: Double? = nil,
        rxTotal: UInt64 = 0,
        txTotal: UInt64 = 0
    ) {
        self.id = id
        self.process = process
        self.app = app
        self.proto = proto
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.remoteHost = remoteHost
        self.tcpState = tcpState
        self.rxBps = rxBps
        self.txBps = txBps
        self.rxTotal = rxTotal
        self.txTotal = txTotal
    }
}
