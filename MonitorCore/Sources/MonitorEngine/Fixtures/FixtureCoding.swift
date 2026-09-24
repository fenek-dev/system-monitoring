import Foundation
import MonitorModel

/// The recorded-fixture format (`telltale-probe --record`, `Tests/MonitorEngineTests/Fixtures/recorded/*.json`):
/// a JSON array of `RawTick`, dates as ISO 8601 with fractional seconds (UTC, millisecond precision), keys sorted.
public extension RawTick {
    static var fixtureEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(FixtureDate.style))
        }
        return e
    }

    static var fixtureDecoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? FixtureDate.style.parse(s) { return date }
            if let date = try? FixtureDate.plain.parse(s) { return date }     // tolerate whole-second stamps
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
        }
        return d
    }
}

enum FixtureDate {
    static let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
    static let plain = Date.ISO8601FormatStyle(timeZone: .gmt)
}
