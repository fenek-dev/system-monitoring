import Foundation

/// The fixed calendar every deterministic date in `MonitorMocks` is built against — Europe/London,
/// matching the snapshot harness (ARCHITECTURE §8: "en_US, Europe/London, dark, scale 2"). Never
/// `Calendar.current`/`TimeZone.current`: those follow the *host machine's* timezone, so
/// `MockDataProvider.referenceDate` and `HistorySignal`'s day/night, weekend and event-bump timing would
/// silently shift (and disagree with the London-pinned goldens) depending on where the build runs.
enum ReferenceCalendar {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = london
        return c
    }()

    static let london: TimeZone = TimeZone(identifier: "Europe/London") ?? TimeZone(secondsFromGMT: 0)!
}
