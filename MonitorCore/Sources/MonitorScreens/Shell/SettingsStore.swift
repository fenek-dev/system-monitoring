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
/// - `DisabledSensors`: array of `SensorID` raw values (ARCHITECTURE §6 kill switch);
/// - `overlay.enabled` (Bool), `overlay.corner` (`OverlayCorner` raw value), `overlay.opacity` (Double, clamped
///   to `overlayOpacityRange`), `overlay.hotkey` (`{keyCode, modifiers}` Carbon ints; invalid → default).
@MainActor @Observable
public final class SettingsStore {
    public enum Key {
        public static let temperature = "units.temperature"
        public static let networkRate = "units.networkRate"
        public static let popoverRows = "popover.rows"
        public static let disabledSensors = "DisabledSensors"
        public static let overlayEnabled = "overlay.enabled"
        public static let overlayCorner = "overlay.corner"
        public static let overlayOpacity = "overlay.opacity"
        public static let overlayHotKey = "overlay.hotkey"
    }

    public static let overlayOpacityDefault = 0.85
    public static let overlayOpacityRange: ClosedRange<Double> = 0.4...1

    @ObservationIgnored public let defaults: UserDefaults

    /// Clears the crash-canary markers ("Disabled after a crash"). The canary owns its keys and domain
    /// (`CrashCanary.reenableAll()` in MonitorEngine); the app injects it through the runtime. Nil in renders.
    @ObservationIgnored public var reenableCrashedSensors: (@MainActor () -> Void)?

    public var units: UnitPreferences {
        didSet { if units != oldValue { saveUnits() } }
    }

    public var popoverLayout: PopoverLayout {
        didSet { if popoverLayout != oldValue { savePopover() } }
    }

    public private(set) var disabledSensors: Set<SensorID>

    // MARK: Overlay (spec 2026-09-25 overlay, "State and settings")

    public var overlayEnabled: Bool {
        didSet { if overlayEnabled != oldValue { defaults.set(overlayEnabled, forKey: Key.overlayEnabled) } }
    }

    public var overlayCorner: OverlayCorner {
        didSet { if overlayCorner != oldValue { defaults.set(overlayCorner.rawValue, forKey: Key.overlayCorner) } }
    }

    /// Always within `overlayOpacityRange`: assignments are clamped before they are stored.
    public var overlayOpacity: Double {
        get { storedOverlayOpacity }
        set {
            let v = Self.clampOpacity(newValue)
            guard v != storedOverlayOpacity else { return }
            storedOverlayOpacity = v
            defaults.set(v, forKey: Key.overlayOpacity)
        }
    }

    private var storedOverlayOpacity: Double

    public var overlayHotKey: HotKeySpec {
        didSet { if overlayHotKey != oldValue { saveHotKey() } }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        units = Self.loadUnits(defaults)
        popoverLayout = Self.loadPopover(defaults)
        disabledSensors = Self.loadDisabled(defaults)
        overlayEnabled = defaults.object(forKey: Key.overlayEnabled) as? Bool ?? false
        overlayCorner = defaults.string(forKey: Key.overlayCorner).flatMap(OverlayCorner.init(rawValue:)) ?? .topRight
        storedOverlayOpacity = Self.clampOpacity((defaults.object(forKey: Key.overlayOpacity) as? NSNumber)?.doubleValue)
        overlayHotKey = Self.loadHotKey(defaults)
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

    /// Settings "Re-enable sensors": clears the kill-switch list and (via the canary's own API) every crash marker.
    /// Takes effect when the runtime next builds its sensors (next launch).
    public func reenableSensors() {
        disabledSensors = []
        defaults.removeObject(forKey: Key.disabledSensors)
        reenableCrashedSensors?()
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

    /// Nil or NaN → default; otherwise clamped into `overlayOpacityRange`.
    static func clampOpacity(_ value: Double?) -> Double {
        guard let value, !value.isNaN else { return overlayOpacityDefault }
        return min(max(value, overlayOpacityRange.lowerBound), overlayOpacityRange.upperBound)
    }

    static func loadHotKey(_ d: UserDefaults) -> HotKeySpec {
        guard let dict = d.dictionary(forKey: Key.overlayHotKey),
              let code = (dict["keyCode"] as? Int).flatMap(UInt32.init(exactly:)),
              let mods = (dict["modifiers"] as? Int).flatMap(UInt32.init(exactly:))
        else { return .defaultOverlay }
        let spec = HotKeySpec(keyCode: code, modifiers: mods)
        return spec.isValid ? spec : .defaultOverlay
    }

    private func saveHotKey() {
        defaults.set(["keyCode": Int(overlayHotKey.keyCode), "modifiers": Int(overlayHotKey.modifiers)],
                     forKey: Key.overlayHotKey)
    }

    private func saveDisabled() {
        if disabledSensors.isEmpty {
            defaults.removeObject(forKey: Key.disabledSensors)
        } else {
            defaults.set(disabledSensors.map(\.rawValue).sorted(), forKey: Key.disabledSensors)
        }
    }
}
