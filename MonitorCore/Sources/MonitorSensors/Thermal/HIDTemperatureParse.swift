import Foundation
import MonitorModel

/// Pure HID temperature list decoding (docs/findings/temps.md): average duplicate services per name,
/// drop ignored names (calibration constants), non-finite and implausible values; group by catalog name patterns.
enum HIDTemperatureParse {
    struct Sample: Codable, Sendable, Equatable {
        var name: String
        var celsius: Double
    }

    static func reading(_ samples: [Sample], catalog: TemperatureCatalog?) -> TemperatureReading {
        var sums: [String: (Double, Int)] = [:]
        for s in samples where !s.name.isEmpty && SMCDecoder.isPlausibleTemperature(s.celsius) {
            let cur = sums[s.name] ?? (0, 0)
            sums[s.name] = (cur.0 + s.celsius, cur.1 + 1)
        }
        var out: [RawTemperature] = []
        out.reserveCapacity(sums.count)
        for (name, (sum, n)) in sums {
            let group: TemperatureGroup?
            if let catalog { group = catalog.hidGroup(name) } else { group = .other }
            guard let group else { continue }
            out.append(RawTemperature(name: name, celsius: sum / Double(n), group: group, source: .hid))
        }
        out.sort { $0.name < $1.name }
        return TemperatureReading(sensors: out)
    }
}
