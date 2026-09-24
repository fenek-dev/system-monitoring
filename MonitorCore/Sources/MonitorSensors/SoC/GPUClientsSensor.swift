import Foundation
import IOKit
import MonitorModel

/// Per-client GPU time from `AGXAccelerator` children (`AGXDeviceUserClient`), public IOKit only.
/// The accelerator service is acquired once in `prepare()` and released once in `invalidate()`.
public final class GPUClientsSensor: Sensor {
    public typealias Reading = GPUClientsReading
    public let id: SensorID = .gpuClients
    public let cadence: SensorCadence = .everyTick

    private var accel: io_service_t = 0

    public init() {}

    deinit { invalidate() }

    public func prepare() throws(SensorError) {
        guard accel == 0 else { return }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard svc != 0 else { throw .unavailable("AGXAccelerator not found") }
        accel = svc
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: GPUClientsReading, capturedNs: UInt64) {
        if accel == 0 { try prepare() }
        var it: io_iterator_t = 0
        let kr = IORegistryEntryGetChildIterator(accel, kIOServicePlane, &it)
        guard kr == KERN_SUCCESS else { throw .transient("AGX child iterator: 0x\(String(UInt32(bitPattern: kr), radix: 16))") }
        defer { IOObjectRelease(it) }
        var reading = GPUClientsReading()
        reading.clients.reserveCapacity(96)
        while case let child = IOIteratorNext(it), child != 0 {
            defer { IOObjectRelease(child) }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(child, &entryID) == KERN_SUCCESS else { continue }
            guard let creator = w6bRegistryProperty(child, "IOUserClientCreator") else { continue }
            if let c = GPUClientsParse.client(id: entryID, creator: creator,
                                             appUsage: w6bRegistryProperty(child, "AppUsage")) {
                reading.clients.append(c)
            }
        }
        let perf = GPUClientsParse.performance(w6bRegistryProperty(accel, "PerformanceStatistics"))
        reading.deviceUtilization = perf.utilization
        reading.inUseSystemMemory = perf.inUseSystemMemory
        return (reading, w6bUptimeNs())
    }

    public func invalidate() {
        if accel != 0 { IOObjectRelease(accel) }
        accel = 0
    }

    /// Raw registry dump for fixtures: [{id, IOUserClientCreator, AppUsage}] + PerformanceStatistics.
    func rawDump() -> [String: Any] {
        guard accel != 0 else { return [:] }
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &it) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(it) }
        var clients: [[String: Any]] = []
        while case let child = IOIteratorNext(it), child != 0 {
            defer { IOObjectRelease(child) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(child, &entryID)
            var c: [String: Any] = ["id": NSNumber(value: entryID)]
            c["IOUserClientCreator"] = w6bRegistryProperty(child, "IOUserClientCreator")
            c["AppUsage"] = w6bRegistryProperty(child, "AppUsage")
            clients.append(c)
        }
        return ["clients": clients, "PerformanceStatistics": w6bRegistryProperty(accel, "PerformanceStatistics") ?? [:]]
    }
}
