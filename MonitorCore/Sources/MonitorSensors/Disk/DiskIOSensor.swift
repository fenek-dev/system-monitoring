import Foundation
import IOKit
import MonitorModel

/// `IOBlockStorageDriver` + `Statistics` (findings/extras.md §1). Raw cumulative counters only — no
/// rates here (ARCHITECTURE §5.3: "no deltas except where the source is inherently delta-based");
/// the engine's `RateCalculator` turns these into `readBps`/`writeIOPS` and guards a counter that
/// resets on replug (a new driver instance restarts at 0). Every driver is enumerated fresh each
/// `sample()` (findings §1: enumerate + read Statistics on every driver costs 0.17-0.63 ms), so a
/// drive that appears or disappears between ticks is simply present-or-absent in the next reading —
/// no hot-plug bookkeeping needed in the sensor itself.
public final class DiskIOSensor: Sensor {
    public typealias Reading = DiskIOReading
    public let id: SensorID = .diskIO
    public let cadence: SensorCadence = .everyTick

    public init() {}

    public func prepare() throws(SensorError) {
        // No persistent handles: IOKit's IOBlockStorageDriver matching is always available and every
        // driver is (re-)enumerated in sample(). Nothing to open ahead of time.
    }

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: DiskIOReading, capturedNs: UInt64) {
        let drivers = ttEnumerateBlockStorageDrivers()
        defer { for driver in drivers { IOObjectRelease(driver) } }

        var counters: [BlockDriverCounter] = []
        counters.reserveCapacity(drivers.count)
        for driver in drivers {
            let stats = DiskIOParser.parseStatistics(ttReadStatistics(driver))
            let media = ttMediaInfo(ofFirstChildOf: driver)
            counters.append(BlockDriverCounter(
                bsdName: media.bsdName,
                isInternal: media.isInternal,
                readOps: stats.readOps,
                writeOps: stats.writeOps,
                readBytes: stats.readBytes,
                writeBytes: stats.writeBytes,
                isDiskImage: ttIsDiskImageDriver(driver)
            ))
        }
        return (DiskIOReading(drivers: counters), ctx.uptimeNs)
    }

    public func invalidate() {}
}
