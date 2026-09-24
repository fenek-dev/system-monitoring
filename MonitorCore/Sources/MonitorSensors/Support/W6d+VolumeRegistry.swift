import Foundation
import IOKit

// W6d volume helpers: BSD-name resolution for a mount path, and bus-label lookup shared with the
// registry-walk pattern in W6d+DiskRegistry.swift.

/// The BSD device name backing `mountPath` (e.g. "/" -> "disk3s3s1"), read from `statfs`'s
/// `f_mntfromname` ("/dev/disk3s3s1" -> "disk3s3s1"). `nil` for a non-device mount (e.g. a network
/// share) or if `statfs` fails.
func ttBSDName(forMountPath mountPath: String) -> String? {
    var buf = statfs()
    guard statfs(mountPath, &buf) == 0 else { return nil }
    let prefix = "/dev/"
    let mountedFrom = withUnsafePointer(to: &buf.f_mntfromname) { ptr -> String in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
    }
    guard mountedFrom.hasPrefix(prefix) else { return nil }
    return String(mountedFrom.dropFirst(prefix.count))
}

/// The transport/bus label for a volume's underlying device (e.g. "Apple Fabric", "USB", "Virtual
/// Interface" for a mounted disk image), read from the first ancestor's `Protocol Characteristics`
/// dict along the IOService parent chain starting at `bsdName`'s `IOMedia`. For a logical volume
/// (an APFS volume's BSD name) this can be several hops deeper than the disk-IO lookups in
/// W6d+DiskRegistry.swift (AppleAPFSVolume -> AppleAPFSContainer -> ... -> the physical device), so
/// the walk allows more hops. `nil` when nothing along the chain carries the property (bounded walk,
/// never a registry sweep) — busLabel is an optional, best-effort field.
func ttBusLabel(forBSDName bsdName: String) -> String? {
    ttWalkIOParentChain(fromBSDName: bsdName, maxHops: 40) { _, props in
        (props["Protocol Characteristics"] as? [String: Any])?["Physical Interconnect"] as? String
    }
}
