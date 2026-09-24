import Foundation

public struct BlockDriverCounter: Sendable, Codable, Hashable {
    public var bsdName: String?, isInternal: Bool
    public var readOps, writeOps, readBytes, writeBytes: UInt64
    /// True for a mounted disk image's driver (ICR 001/11, W6d): its reported I/O duplicates activity
    /// already counted on the physical driver backing the image file, so a system-wide disk-I/O total
    /// should exclude it rather than double-count. Additive: defaults to `false` when decoding a
    /// recorded fixture from before this field existed.
    public var isDiskImage: Bool

    public init(
        bsdName: String? = nil,
        isInternal: Bool = false,
        readOps: UInt64 = 0,
        writeOps: UInt64 = 0,
        readBytes: UInt64 = 0,
        writeBytes: UInt64 = 0,
        isDiskImage: Bool = false
    ) {
        self.bsdName = bsdName
        self.isInternal = isInternal
        self.readOps = readOps
        self.writeOps = writeOps
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.isDiskImage = isDiskImage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bsdName = try c.decodeIfPresent(String.self, forKey: .bsdName)
        isInternal = try c.decode(Bool.self, forKey: .isInternal)
        readOps = try c.decode(UInt64.self, forKey: .readOps)
        writeOps = try c.decode(UInt64.self, forKey: .writeOps)
        readBytes = try c.decode(UInt64.self, forKey: .readBytes)
        writeBytes = try c.decode(UInt64.self, forKey: .writeBytes)
        // decodeIfPresent + default: a fixture recorded before ICR 001/11 has no "isDiskImage" key.
        isDiskImage = try c.decodeIfPresent(Bool.self, forKey: .isDiskImage) ?? false
    }
}

public struct DiskIOReading: Sendable, Codable {
    public var drivers: [BlockDriverCounter]

    public init(drivers: [BlockDriverCounter] = []) {
        self.drivers = drivers
    }
}

public struct VolumeInfo: Sendable, Codable, Hashable, Identifiable {
    public var id: String, name: String, bsdName: String?, fsType: String?, busLabel: String?
    public var isInternal, isEjectable, isEncrypted: Bool
    public var totalBytes: UInt64, availableBytes: UInt64, availableImportantBytes: UInt64?

    /// Space the system can free on demand: `availableImportantBytes − availableBytes` (clamped ≥ 0).
    public var purgeableBytes: UInt64? {
        guard let important = availableImportantBytes else { return nil }
        return important > availableBytes ? important - availableBytes : 0
    }

    public init(
        id: String = "",
        name: String = "",
        bsdName: String? = nil,
        fsType: String? = nil,
        busLabel: String? = nil,
        isInternal: Bool = false,
        isEjectable: Bool = false,
        isEncrypted: Bool = false,
        totalBytes: UInt64 = 0,
        availableBytes: UInt64 = 0,
        availableImportantBytes: UInt64? = nil
    ) {
        self.id = id
        self.name = name
        self.bsdName = bsdName
        self.fsType = fsType
        self.busLabel = busLabel
        self.isInternal = isInternal
        self.isEjectable = isEjectable
        self.isEncrypted = isEncrypted
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableImportantBytes = availableImportantBytes
    }
}

public struct VolumesReading: Sendable, Codable {
    public var volumes: [VolumeInfo]

    public init(volumes: [VolumeInfo] = []) {
        self.volumes = volumes
    }
}

public enum SMARTStatus: String, Sendable, Codable { case healthy, warning, failing, unknown }

public struct SMARTInfo: Sendable, Codable, Equatable {
    public var model: String?, capacityBytes: UInt64?, status: SMARTStatus
    public var percentageUsed: Double?, dataReadBytes: UInt64?, dataWrittenBytes: UInt64?
    public var temperatureC: Double?, powerOnHours: Int?, unsafeShutdowns: Int?, criticalWarning: UInt8?

    public init(
        model: String? = nil,
        capacityBytes: UInt64? = nil,
        status: SMARTStatus = .unknown,
        percentageUsed: Double? = nil,
        dataReadBytes: UInt64? = nil,
        dataWrittenBytes: UInt64? = nil,
        temperatureC: Double? = nil,
        powerOnHours: Int? = nil,
        unsafeShutdowns: Int? = nil,
        criticalWarning: UInt8? = nil
    ) {
        self.model = model
        self.capacityBytes = capacityBytes
        self.status = status
        self.percentageUsed = percentageUsed
        self.dataReadBytes = dataReadBytes
        self.dataWrittenBytes = dataWrittenBytes
        self.temperatureC = temperatureC
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.criticalWarning = criticalWarning
    }
}
