import Foundation
import IOKit

// W6d NVMe SMART service lookup (findings/extras.md §2). Two paths, mirroring smartctl: a cheap
// (~0.6 ms) targeted walk up the BSD disk's parent chain, and a full-registry sweep (~11 ms, ~18x
// more expensive) only as a fallback if the targeted walk finds nothing.

/// Result of locating the NVMe SMART-capable service backing a BSD disk: the service itself
/// (retained; caller releases) plus whatever model name ("Device Characteristics" -> "Product Name")
/// was seen along the way — a bonus, not guaranteed to be on the same node as "NVMe SMART Capable"
/// on every controller, so it's tracked independently while walking.
struct TTNVMeSMARTLookup { var service: io_service_t; var model: String? }

/// Targeted lookup (findings §2): starting at `bsdName`'s `IOMedia`, walk UP the IOService parent
/// chain (shared `ttWalkIOParentChain`) until a node has `"NVMe SMART Capable" == true` (a few hops
/// for a whole-disk BSD name like "disk0"; more for a logical/APFS volume's BSD name). `nil` if
/// `bsdName` doesn't resolve or nothing within `maxHops` is SMART-capable (e.g. a non-NVMe drive).
func ttFindNVMeSMARTService(bsdName: String, maxHops: Int = 30) -> TTNVMeSMARTLookup? {
    var model: String?
    guard let service = ttWalkIOParentChain(fromBSDName: bsdName, maxHops: maxHops, visit: { node, props -> io_service_t? in
        if model == nil, let deviceCharacteristics = props["Device Characteristics"] as? [String: Any] {
            model = deviceCharacteristics["Product Name"] as? String
        }
        guard (props["NVMe SMART Capable"] as? NSNumber)?.boolValue == true else { return nil }
        IOObjectRetain(node)
        return node
    }) else { return nil }
    return TTNVMeSMARTLookup(service: service, model: model)
}

/// Fallback (findings §2): sweep every `IOService` and filter by `"NVMe SMART Capable" == true`.
/// Correct but ~18x more expensive than the targeted walk; only used when that walk finds nothing.
/// Not anchored to any particular BSD name — the caller must not attach another drive's identity
/// (model/capacity) to whatever this finds.
func ttFindNVMeSMARTServiceBySweep() -> io_service_t {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOServiceClass), &iter) == KERN_SUCCESS else {
        return 0
    }
    defer { IOObjectRelease(iter) }
    var found: io_service_t = 0
    var service = IOIteratorNext(iter)
    while service != 0 {
        if found == 0,
           let cf = IORegistryEntryCreateCFProperty(service, "NVMe SMART Capable" as CFString, kCFAllocatorDefault, 0),
           (cf.takeRetainedValue() as? NSNumber)?.boolValue == true {
            found = service
        } else {
            IOObjectRelease(service)
        }
        service = IOIteratorNext(iter)
    }
    return found
}

/// Legacy ATA/AHCI SMART pass/fail (brief: "else status only"; ARCHITECTURE §6's SMART status-only
/// panel), for a drive with no working NVMe SMART interface. Walks the same parent chain looking for
/// the `"SMART Status"` property (`IOBlockStorageDevice`/`IOAHCIBlockStorageDevice`: `"Verified"` or
/// `"Failing"`). Not exercised live in this stream's testing — this machine's internal drive is NVMe
/// only — but is the documented fallback path a SATA/AHCI Mac would take.
func ttReadLegacySMARTStatus(bsdName: String, maxHops: Int = 30) -> String? {
    ttWalkIOParentChain(fromBSDName: bsdName, maxHops: maxHops) { _, props in
        props["SMART Status"] as? String
    }
}

/// The internal (non-ejectable) block-storage drive's BSD name and whole-disk capacity, from a
/// single driver enumeration (one `ttEnumerateBlockStorageDrivers` + one child-media property fetch
/// per driver — not two independent passes). The natural SMART target absent a more specific
/// selection (ARCHITECTURE: `smart` is a single sensor slot, not one per drive). `nil` if no internal
/// drive resolves a BSD name at all.
struct TTInternalDriveIdentity { var bsdName: String; var capacityBytes: UInt64? }

func ttInternalDriveIdentity() -> TTInternalDriveIdentity? {
    let drivers = ttEnumerateBlockStorageDrivers()
    defer { for driver in drivers { IOObjectRelease(driver) } }
    for driver in drivers {
        let media = ttMediaInfo(ofFirstChildOf: driver)
        if media.isInternal, let bsdName = media.bsdName {
            return TTInternalDriveIdentity(bsdName: bsdName, capacityBytes: media.sizeBytes)
        }
    }
    return nil
}
