import Foundation
import IOKit

// Shared IOKit registry-walk helpers for the disk sensors (W6d, findings/extras.md §1-§2).
// `IOBlockStorageDriver` enumeration and BSD-name resolution are shared by DiskIOSensor and
// SMARTSensor; the parent-chain walk pattern is shared by SMARTSensor (NVMe SMART capability)
// and VolumeSensor (bus label).

/// Every `IOBlockStorageDriver` service currently in the registry. Each entry is retained; the
/// caller must `IOObjectRelease` it. Enumerated fresh on every call (no cached list) so a
/// hot-plugged or removed drive is picked up on the very next sample.
func ttEnumerateBlockStorageDrivers() -> [io_service_t] {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else {
        return []
    }
    defer { IOObjectRelease(iter) }
    var result: [io_service_t] = []
    var service = IOIteratorNext(iter)
    while service != 0 {
        result.append(service)
        service = IOIteratorNext(iter)
    }
    return result
}

/// The media identity of an `IOBlockStorageDriver`'s child `IOMedia`. Findings §1: `BSD Name`
/// lives on the CHILD, not the parent (the brief's "name the parent media" is backwards). A driver
/// with no media child (a real, if rare, case — findings §1) yields `bsdName == nil`.
struct TTDriverMediaInfo {
    var bsdName: String?
    /// Heuristic: the child `IOMedia`'s `Ejectable` property, inverted. True for the internal SSD's
    /// whole-disk media; true (isInternal=false) for mounted disk images and external volumes.
    var isInternal: Bool
    var sizeBytes: UInt64?
}

/// Reads `{BSD Name, Ejectable, Size}` off the first child of `driver` that carries a BSD Name, in
/// one `IORegistryEntryCreateCFProperties` call (cheaper than one `IORegistryEntryCreateCFProperty`
/// call per key). Releases every child it iterates.
func ttMediaInfo(ofFirstChildOf driver: io_service_t) -> TTDriverMediaInfo {
    var iter: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(driver, kIOServicePlane, &iter) == KERN_SUCCESS else {
        return TTDriverMediaInfo(bsdName: nil, isInternal: false, sizeBytes: nil)
    }
    defer { IOObjectRelease(iter) }
    var result = TTDriverMediaInfo(bsdName: nil, isInternal: false, sizeBytes: nil)
    var child = IOIteratorNext(iter)
    while child != 0 {
        if result.bsdName == nil {
            var propsUnmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(child, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = propsUnmanaged?.takeRetainedValue() as? [String: Any],
               let bsdName = props["BSD Name"] as? String {
                let ejectable = (props["Ejectable"] as? NSNumber)?.boolValue ?? false
                let size = (props["Size"] as? NSNumber)?.uint64Value
                result = TTDriverMediaInfo(bsdName: bsdName, isInternal: !ejectable, sizeBytes: size)
            }
        }
        IOObjectRelease(child)
        child = IOIteratorNext(iter)
    }
    return result
}

/// The `Statistics` property of an `IOBlockStorageDriver`, as the plain dictionary the parse layer
/// (`DiskIOParser`) consumes. Empty when the property is missing or of an unexpected type.
func ttReadStatistics(_ driver: io_service_t) -> [String: Any] {
    guard let cf = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0),
          let dict = cf.takeRetainedValue() as? [String: Any] else {
        return [:]
    }
    return dict
}

/// Walks UP the IOService parent chain from the entry matching `bsdName`, releasing every
/// intermediate node, up to `maxHops`. Returns `nil` if `bsdName` doesn't resolve or nothing along
/// the chain satisfies `visit`. `visit` gets `(node, properties)`; the node is only valid for the
/// duration of that call — retain it (`IOObjectRetain`) before returning it as part of a result.
func ttWalkIOParentChain<T>(
    fromBSDName bsdName: String,
    maxHops: Int = 30,
    visit: (io_service_t, [String: Any]) -> T?
) -> T? {
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
    var current = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard current != 0 else { return nil }
    var hops = 0
    while hops < maxHops {
        var propsUnmanaged: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(current, &propsUnmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let props = propsUnmanaged?.takeRetainedValue() as? [String: Any],
           let result = visit(current, props) {
            IOObjectRelease(current)
            return result
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
