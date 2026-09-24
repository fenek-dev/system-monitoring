import Darwin
import Foundation
import MonitorModel

/// Local mounted volumes (capacity, purgeable, internal/external). The mount table comes from
/// `getfsstat(MNT_NOWAIT)`, which never touches a mount, and is filtered to local, browsable volumes
/// (`MNT_LOCAL`, not `MNT_DONTBROWSE` — the set `mountedVolumeURLs(.skipHiddenVolumes)` shows) BEFORE any
/// capacity call: statfs/getattrlist against a dead SMB/NFS mount blocks the sampler for tens of seconds or
/// forever (final review S-I3). Network volumes are skipped; the Disk page lists local volumes only.
/// Bus label is a best-effort IOKit registry walk (W6d+VolumeRegistry.swift).
public final class VolumeSensor: Sensor {
    public typealias Reading = VolumesReading
    public let id: SensorID = .volumes
    public let cadence: SensorCadence = .every(.seconds(10), background: .seconds(60))

    /// One `getfsstat` entry.
    struct Mount: Equatable, Sendable {
        var path: String
        /// `f_mntfromname` ("/dev/disk3s3s1", "//user@nas/share", "map auto_home").
        var from: String
        var flags: UInt32
    }

    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsEncryptedKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeTypeNameKey,
    ]

    private let mountTable: () -> [Mount]
    private let resourceValues: (String) -> URLResourceValues?

    public convenience init() {
        self.init(mountTable: Self.systemMounts) { path in
            try? URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: Self.keys)
        }
    }

    /// Test seam: a fake mount table and a recording resource-values lookup.
    init(mountTable: @escaping () -> [Mount], resourceValues: @escaping (String) -> URLResourceValues?) {
        self.mountTable = mountTable
        self.resourceValues = resourceValues
    }

    public func prepare() throws(SensorError) {}

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: VolumesReading, capturedNs: UInt64) {
        let mounts = Self.localVolumes(mountTable())
        var volumes: [VolumeInfo] = []
        volumes.reserveCapacity(mounts.count)
        for m in mounts {
            guard let values = resourceValues(m.path) else { continue }
            let bsdName = Self.bsdName(mountedFrom: m.from)
            let raw = RawVolumeInfo(
                mountPath: m.path,
                name: values.volumeName,
                bsdName: bsdName,
                fsType: values.volumeTypeName,
                busLabel: bsdName.flatMap { ttBusLabel(forBSDName: $0) },
                isInternal: values.volumeIsInternal,
                isEjectable: values.volumeIsEjectable,
                isEncrypted: values.volumeIsEncrypted,
                totalBytes: values.volumeTotalCapacity.map { UInt64($0) },
                availableBytes: values.volumeAvailableCapacity.map { UInt64($0) },
                availableImportantBytes: values.volumeAvailableCapacityForImportantUsage.map { UInt64($0) }
            )
            volumes.append(VolumeParser.map(raw))
        }
        return (VolumesReading(volumes: volumes), ctx.uptimeNs)
    }

    public func invalidate() {}

    // MARK: - Pure

    /// Local, browsable mounts, in mount-table order.
    static func localVolumes(_ mounts: [Mount]) -> [Mount] {
        mounts.filter { $0.flags & UInt32(MNT_LOCAL) != 0 && $0.flags & UInt32(MNT_DONTBROWSE) == 0 }
    }

    /// "/dev/disk3s3s1" → "disk3s3s1"; nil for a non-device mount.
    static func bsdName(mountedFrom from: String) -> String? {
        guard from.hasPrefix("/dev/"), from.count > 5 else { return nil }
        return String(from.dropFirst(5))
    }

    // MARK: - FFI

    /// `getfsstat(MNT_NOWAIT)`: the kernel's cached mount table, no call into any file system. Retries once
    /// when a mount appears between the count and the copy.
    static func systemMounts() -> [Mount] {
        for _ in 0..<3 {
            let n = getfsstat(nil, 0, MNT_NOWAIT)
            guard n > 0 else { return [] }
            let capacity = Int(n) + 4
            var buf: [statfs] = Array(repeating: statfs(), count: capacity)
            let got = buf.withUnsafeMutableBufferPointer {
                getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            }
            guard got >= 0 else { return [] }
            if Int(got) == capacity { continue }                 // table may have grown past the buffer
            return buf.prefix(Int(got)).map { s in
                var s = s
                return Mount(path: cString(&s.f_mntonname), from: cString(&s.f_mntfromname), flags: s.f_flags)
            }
        }
        return []
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
