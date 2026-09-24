import Foundation

public struct DiskSnapshot: Sendable, Codable, Equatable {
    public var readBps: Double?, writeBps: Double?, readIOPS: Double?, writeIOPS: Double?
    public var volumes: [VolumeInfo], smart: SMARTInfo?

    /// The volume mounted at "/" (`VolumeInfo.id == "/"`), else the first internal volume.
    public var bootVolume: VolumeInfo? {
        volumes.first { $0.id == "/" } ?? volumes.first { $0.isInternal }
    }

    public init(
        readBps: Double? = nil,
        writeBps: Double? = nil,
        readIOPS: Double? = nil,
        writeIOPS: Double? = nil,
        volumes: [VolumeInfo] = [],
        smart: SMARTInfo? = nil
    ) {
        self.readBps = readBps
        self.writeBps = writeBps
        self.readIOPS = readIOPS
        self.writeIOPS = writeIOPS
        self.volumes = volumes
        self.smart = smart
    }
}
