import Foundation

/// Pure parse layer for `IOBlockStorageDriver`'s `Statistics` property (findings/extras.md §1).
/// No IOKit here — this is exactly what a captured dump (`Fixtures/W6d/disk-io-statistics.json`)
/// round-trips through, so it's testable without touching hardware.
enum DiskIOParser {
    struct Counters: Equatable {
        var readOps: UInt64
        var writeOps: UInt64
        var readBytes: UInt64
        var writeBytes: UInt64
    }

    /// `raw` is whatever `IORegistryEntryCreateCFProperty(_, "Statistics", ...)` handed back, cast to
    /// `[String: Any]` (every value is really an `NSNumber`). Missing or non-numeric keys read as 0 —
    /// a driver's Statistics dict is always present in practice, but this must never crash on a
    /// registry shape change.
    static func parseStatistics(_ raw: [String: Any]) -> Counters {
        func u64(_ key: String) -> UInt64 {
            (raw[key] as? NSNumber)?.uint64Value ?? 0
        }
        return Counters(
            readOps: u64("Operations (Read)"),
            writeOps: u64("Operations (Write)"),
            readBytes: u64("Bytes (Read)"),
            writeBytes: u64("Bytes (Write)")
        )
    }
}
