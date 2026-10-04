import Foundation
import MonitorModel
@testable import MonitorScreens
import Testing

@Suite("StorageFormat")
struct StorageFormatTests {
    static let scannedAgoCases: [(TimeInterval, String)] = {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86_400
        var cases: [(TimeInterval, String)] = []
        cases.append((0, "Scanned just now"))
        cases.append((59, "Scanned just now"))
        cases.append((minute, "Scanned 1 min ago"))
        cases.append((59 * minute, "Scanned 59 min ago"))
        cases.append((hour, "Scanned 1 h ago"))
        cases.append((23 * hour + 59 * minute, "Scanned 23 h ago"))
        cases.append((day, "Scanned 1 d ago"))
        cases.append((6 * day + 23 * hour, "Scanned 6 d ago"))
        cases.append((7 * day, "Scanned 14 Sep"))
        cases.append((-30, "Scanned just now"))
        return cases
    }()

    /// Bug: an estimate rendered as an exact size.
    @Test(arguments: [
        (UInt64?.some(12_000_000_000), SizeProvenance.exact, "12.0 GB"),
        (UInt64?.some(12_000_000_000), SizeProvenance.estimate, "≈12.0 GB"),
        (UInt64?.some(12_000_000_000), SizeProvenance.unavailable, "—"),
        (UInt64?.none, SizeProvenance.exact, "—"),
    ])
    func bytes(value: UInt64?, provenance: SizeProvenance, expected: String) {
        #expect(StorageFormat.bytes(value, provenance: provenance) == expected)
    }

    /// Bugs: off-by-one unit boundaries, "1 hours", wall-clock leak (`now` is injected).
    @Test(arguments: scannedAgoCases)
    func scannedAgo(age: TimeInterval, expected: String) {
        let now = Date(timeIntervalSince1970: 1_790_000_000)    // 2026-09-21 UTC
        let text = StorageFormat.scannedAgo(now.addingTimeInterval(-age), now: now,
                                            locale: Locale(identifier: "en_GB"),
                                            timeZone: TimeZone(identifier: "UTC")!)
        #expect(text == expected)
    }

    /// Bug: "1 items".
    @Test(arguments: [(1, "Selected 1.0 GB · 1 item"), (2, "Selected 1.0 GB · 2 items")])
    func selection(count: Int, expected: String) {
        #expect(StorageFormat.selection(bytes: 1_000_000_000, provenance: .exact, count: count) == expected)
    }
}
