import Foundation
import MonitorModel
import Observation

/// User settings (DESIGN §3.14), persisted in one `UserDefaults` suite per data directory.
///
/// Storage is key-per-field with plain property-list values, never a synthesized `Codable` blob, so a missing,
/// partial or stale value falls back to its default field by field:
/// - `units.temperature`, `units.networkRate`: raw-value strings;
/// - `popover.rows`: ordered array of `{id, visible}` dictionaries (DESIGN §3.14); unknown ids are dropped,
///   missing categories are appended visible, and at least one row stays visible;
/// - `DisabledSensors`: array of `SensorID` raw values (ARCHITECTURE §6 kill switch).
@MainActor @Observable
public final class SettingsStore {
    public enum Key {
        public static let temperature = "units.temperature"
        public static let networkRate = "units.networkRate"
        public static let popoverRows = "popover.rows"
        public static let disabledSensors = "DisabledSensors"
    }

    /// Prefix of per-sensor crash-canary markers cleared by "Re-enable sensors" (see w4-report ICR note:
    /// `CrashCanary` exposes no clear API yet).
    public static let crashMarkerPrefix = "CrashCanary."

    @ObservationIgnored public let defaults: UserDefaults

    public var units: UnitPreferences {
        didSet { if units != oldValue { saveUnits() } }
    }

    public var popoverLayout: PopoverLayout {
        didSet { if popoverLayout != oldValue { savePopover() } }
    }

    public private(set) var disabledSensors: Set<SensorID>

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        units = Self.loadUnits(defaults)
        popoverLayout = Self.loadPopover(defaults)
        disabledSensors = Self.loadDisabled(defaults)
    }

    /// `nil` → `.standard`; otherwise a suite named after the directory, so every worktree
    /// (`scripts/run.sh` sets `TELLTALE_DATA_DIR`) keeps its own settings.
    public static func defaults(for dataDirectory: URL?) -> UserDefaults {
        guard let dir = dataDirectory else { return .standard }
        return UserDefaults(suiteName: suiteName(for: dir)) ?? .standard
    }

    public static func suiteName(for dataDirectory: URL) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325                        // FNV-1a, stable across launches
        for b in dataDirectory.standardizedFileURL.path.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return "dev.telltale.Telltale.data-" + String(h, radix: 16)
    }

    // MARK: - Popover rows

    /// Visible rows in order (what the popover shows).
    public var visibleRows: [MonitorModel.Category] {
        popoverLayout.order.filter { !popoverLayout.hidden.contains($0) }
    }

    public func isVisible(_ c: MonitorModel.Category) -> Bool { !popoverLayout.hidden.contains(c) }

    /// False for the last visible row (DESIGN §3.14: its checkbox is disabled).
    public func canHide(_ c: MonitorModel.Category) -> Bool {
        !isVisible(c) || visibleRows.count > 1
    }

    public func setVisible(_ c: MonitorModel.Category, _ visible: Bool) {
        if visible {
            popoverLayout.hidden.remove(c)
        } else if canHide(c) {
            popoverLayout.hidden.insert(c)
        }
    }

    /// `List.onMove` semantics.
    public func moveRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        var order = popoverLayout.order
        let moving = source.sorted().map { order[$0] }
        for i in source.sorted(by: >) { order.remove(at: i) }
        let before = source.filter { $0 < destination }.count
        order.insert(contentsOf: moving, at: min(max(destination - before, 0), order.count))
        popoverLayout.order = order
    }

    // MARK: - Sensors

    public func setDisabled(_ id: SensorID, _ disabled: Bool) {
        if disabled { disabledSensors.insert(id) } else { disabledSensors.remove(id) }
        saveDisabled()
    }

    /// Settings "Re-enable sensors": clears the kill-switch list and every crash marker in this suite.
    /// Takes effect when the runtime next builds its sensors (next launch).
    public func reenableSensors() {
        disabledSensors = []
        defaults.removeObject(forKey: Key.disabledSensors)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.crashMarkerPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Load / save

    private static func loadUnits(_ d: UserDefaults) -> UnitPreferences {
        var u = UnitPreferences()
        if let t = d.string(forKey: Key.temperature).flatMap(UnitPreferences.Temperature.init(rawValue:)) {
            u.temperature = t
        }
        if let n = d.string(forKey: Key.networkRate).flatMap(UnitPreferences.NetworkRate.init(rawValue:)) {
            u.networkRate = n
        }
        return u
    }

    private func saveUnits() {
        defaults.set(units.temperature.rawValue, forKey: Key.temperature)
        defaults.set(units.networkRate.rawValue, forKey: Key.networkRate)
    }

    static func loadPopover(_ d: UserDefaults) -> PopoverLayout {
        guard let rows = d.array(forKey: Key.popoverRows) else { return PopoverLayout() }
        var order: [MonitorModel.Category] = []
        var hidden: Set<MonitorModel.Category> = []
        for case let row as [String: Any] in rows {
            guard let id = row["id"] as? String, let c = MonitorModel.Category(rawValue: id), !order.contains(c)
            else { continue }
            order.append(c)
            if (row["visible"] as? Bool) == false { hidden.insert(c) }
        }
        for c in MonitorModel.Category.allCases where !order.contains(c) { order.append(c) }
        if hidden.count >= order.count, let first = order.first { hidden.remove(first) }
        return PopoverLayout(order: order, hidden: hidden)
    }

    private func savePopover() {
        let rows: [[String: Any]] = popoverLayout.order.map {
            ["id": $0.rawValue, "visible": !popoverLayout.hidden.contains($0)]
        }
        defaults.set(rows, forKey: Key.popoverRows)
    }

    private static func loadDisabled(_ d: UserDefaults) -> Set<SensorID> {
        if let list = d.array(forKey: Key.disabledSensors) {
            return Set(list.compactMap { ($0 as? String).flatMap(SensorID.init(rawValue:)) })
        }
        if let s = d.string(forKey: Key.disabledSensors) { return LaunchOptions.parseSensorList(s) }
        return []
    }

    private func saveDisabled() {
        if disabledSensors.isEmpty {
            defaults.removeObject(forKey: Key.disabledSensors)
        } else {
            defaults.set(disabledSensors.map(\.rawValue).sorted(), forKey: Key.disabledSensors)
        }
    }
}
