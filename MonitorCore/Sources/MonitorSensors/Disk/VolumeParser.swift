import Foundation
import MonitorModel

/// Plain-data mirror of the `URLResourceValues` fields `VolumeSensor` reads, decoupled from
/// Foundation's `URLResourceValues`/`URL` so the mapping to `VolumeInfo` is a pure function
/// (testable with fixtures, no filesystem I/O). `mountPath` is the volume's `URL.path`.
struct RawVolumeInfo: Codable, Equatable {
    var mountPath: String
    var name: String?
    var bsdName: String?
    var fsType: String?
    var busLabel: String?
    var isInternal: Bool?
    var isEjectable: Bool?
    var isEncrypted: Bool?
    var totalBytes: UInt64?
    var availableBytes: UInt64?
    var availableImportantBytes: UInt64?
}

/// Pure parse/mapping layer for volumes (ARCHITECTURE §5.3 `VolumeInfo`). The W0a review ruling:
/// `VolumeInfo.id` must be the volume's mount path, so `DiskSnapshot.bootVolume` can find "/" by
/// `id == "/"` — this is the one thing this mapper must never get wrong.
enum VolumeParser {
    static func map(_ raw: RawVolumeInfo) -> VolumeInfo {
        VolumeInfo(
            id: raw.mountPath,
            name: raw.name ?? raw.mountPath,
            bsdName: raw.bsdName,
            fsType: raw.fsType,
            busLabel: raw.busLabel,
            isInternal: raw.isInternal ?? true,
            isEjectable: raw.isEjectable ?? false,
            isEncrypted: raw.isEncrypted ?? false,
            totalBytes: raw.totalBytes ?? 0,
            availableBytes: raw.availableBytes ?? 0,
            availableImportantBytes: raw.availableImportantBytes
        )
    }
}
