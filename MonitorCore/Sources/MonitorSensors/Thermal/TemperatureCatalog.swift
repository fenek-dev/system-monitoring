import Foundation
import MonitorModel

/// SMC T-key / HID sensor-name → `TemperatureGroup` (`Thermal/Resources/temperature-catalog.json`).
/// Known models map EXACT SMC keys (read directly at prepare, no sweep needed). Unknown models get generic
/// family patterns, resolved against the cached key sweep, and `catalogMatched == false` (UI: approximate map).
struct TemperatureCatalog: Codable, Sendable, Equatable {
    struct Model: Codable, Sendable, Equatable {
        var name: String
        /// `hw.model` prefixes ("MacBookPro18,").
        var prefixes: [String]
        /// Exact SMC key → group.
        var smc: [String: TemperatureGroup]
    }

    struct Pattern: Codable, Sendable, Equatable {
        /// Glob: `*` any run, `?` one character (case-sensitive; SMC keys mix cases: `Tg0K` ≠ `Tg0k`).
        var pattern: String
        var group: TemperatureGroup
    }

    var version: Int
    var models: [Model]
    /// Unknown-model SMC families (approximate).
    var generic: [Pattern]
    /// HID `Product` names → group (raw list labels).
    var hid: [Pattern]
    /// HID names that are not live readings (e.g. `PMU tcal`, a calibration constant).
    var hidIgnore: [String]

    static func bundled() throws(SensorError) -> TemperatureCatalog {
        try w6bLoadResource("temperature-catalog", as: TemperatureCatalog.self)
    }

    /// The model entry whose prefix matches `hwModel` (longest prefix wins); nil → generic.
    func model(for hwModel: String) -> Model? {
        var best: (Model, Int)?
        for m in models {
            for p in m.prefixes where !p.isEmpty && hwModel.hasPrefix(p) && p.count > (best?.1 ?? 0) { best = (m, p.count) }
        }
        return best?.0
    }

    /// Group of an SMC key: exact model map first, then (unknown model only) generic patterns.
    func smcGroup(_ key: String, model: Model?) -> TemperatureGroup? {
        if let model { return model.smc[key] }
        return generic.first { Self.glob($0.pattern, key) }?.group
    }

    /// Group of a HID name; `.other` when unmapped; nil when ignored.
    func hidGroup(_ name: String) -> TemperatureGroup? {
        if hidIgnore.contains(name) { return nil }
        return hid.first { Self.glob($0.pattern, name) }?.group ?? .other
    }

    /// Minimal glob (`*`, `?`), case-sensitive.
    static func glob(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern.unicodeScalars), t = Array(s.unicodeScalars)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] { pi += 1; ti += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = ti; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
