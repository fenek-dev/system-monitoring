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
/// chain until a node has `"NVMe SMART Capable" == true` (a few hops for a whole-disk BSD name like
/// "disk0"; more for a logical/APFS volume's BSD name). `nil` if `bsdName` doesn't resolve or nothing
/// within `maxHops` is SMART-capable (e.g. a non-NVMe drive).
func ttFindNVMeSMARTService(bsdName: String, maxHops: Int = 30) -> TTNVMeSMARTLookup? {
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
    var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard current != 0 else { return nil }
    var model: String?
    var hops = 0
    while hops < maxHops {
        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(current, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let props = propsUnmanaged?.takeRetainedValue() as? [String: Any] {
            if model == nil, let deviceCharacteristics = props["Device Characteristics"] as? [String: Any] {
                model = deviceCharacteristics["Product Name"] as? String
            }
            if (props["NVMe SMART Capable"] as? NSNumber)?.boolValue == true {
                return TTNVMeSMARTLookup(service: current, model: model)
            }
        }
        var parent: io_registry_entry_t = 0
        let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
        IOObjectRelease(current)
        guard kr == KERN_SUCCESS, parent != 0 else { return nil }
        current = parent
        hops += 1
    }
    IOObjectRelease(current)
    return nil
}

/// Fallback (findings §2): sweep every `IOService` and filter by `"NVMe SMART Capable" == true`.
/// Correct but ~18x more expensive than the targeted walk; only used when that walk finds nothing.
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

/// The internal (non-ejectable) block-storage drive's BSD name — the natural SMART target absent a
/// more specific selection (ARCHITECTURE: `smart` is a single sensor slot, not one per drive). `nil`
/// if no internal drive resolves a BSD name at all.
func ttInternalDriveBSDName() -> String? {
    let drivers = ttEnumerateBlockStorageDrivers()
    defer { for driver in drivers { IOObjectRelease(driver) } }
    for driver in drivers {
        let media = ttMediaInfo(ofFirstChildOf: driver)
        if media.isInternal, let bsdName = media.bsdName {
            return bsdName
        }
    }
    return nil
}

/// The internal drive's whole-disk capacity in bytes, read alongside `ttInternalDriveBSDName` (same
/// child-media property fetch, so this is effectively free once you're already looking up the BSD
/// name). `nil` if no internal drive resolves a size.
func ttInternalDriveCapacityBytes() -> UInt64? {
    let drivers = ttEnumerateBlockStorageDrivers()
    defer { for driver in drivers { IOObjectRelease(driver) } }
    for driver in drivers {
        let media = ttMediaInfo(ofFirstChildOf: driver)
        if media.isInternal, media.bsdName != nil, let size = media.sizeBytes {
            return size
        }
    }
    return nil
}
