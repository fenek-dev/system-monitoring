import Foundation
import MonitorModel

/// `URLResourceValues` for every mounted volume (capacity, purgeable, internal/external). Bus label
/// is a best-effort IOKit registry-walk lookup (W6d+VolumeRegistry.swift); everything else comes
/// straight from Foundation, so there's no weak-symbol/hardware-availability failure mode here —
/// `FileManager.mountedVolumeURLs` always resolves at least "/".
public final class VolumeSensor: Sensor {
    public typealias Reading = VolumesReading
    public let id: SensorID = .volumes
    public let cadence: SensorCadence = .every(.seconds(10), background: .seconds(60))

    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsEncryptedKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeTypeNameKey, .volumeIsLocalKey,
    ]

    public init() {}

    public func prepare() throws(SensorError) {}

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: VolumesReading, capturedNs: UInt64) {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys, options: [.skipHiddenVolumes]) ?? []
        var volumes: [VolumeInfo] = []
        volumes.reserveCapacity(urls.count)
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(Self.keys)) else { continue }
            let mountPath = url.path
            // A non-local volume (SMB/NFS/AFP share) has no BSD device, and a hung/unreachable server
            // can make a syscall against its mount point (statfs) or an IOKit walk against a made-up
            // BSD name block well past the sensor's 250 ms budget. Only local volumes get either.
            let isLocal = values.volumeIsLocal ?? true
            let bsdName = isLocal ? ttBSDName(forMountPath: mountPath) : nil
            let busLabel = isLocal ? bsdName.flatMap { ttBusLabel(forBSDName: $0) } : nil
            let raw = RawVolumeInfo(
                mountPath: mountPath,
                name: values.volumeName,
                bsdName: bsdName,
                fsType: values.volumeTypeName,
                busLabel: busLabel,
                isInternal: isLocal ? values.volumeIsInternal : false,
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
}
