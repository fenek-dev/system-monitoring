import Foundation
import IOKit

// W6d volume helper: bus-label lookup shared with the registry-walk pattern in W6d+DiskRegistry.swift.
// (The BSD name comes from getfsstat's f_mntfromname in VolumeSensor — no per-mount statfs.)

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
