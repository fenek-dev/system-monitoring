import Foundation
import MonitorModel
import Observation

/// Clipboard history as the app reports it, shown in Settings.
public struct ClipboardStatus: Equatable, Sendable {
    public var needsAccessibility: Bool
    public var itemCount: Int
    public var byteSize: Int64

    public init(needsAccessibility: Bool = false, itemCount: Int = 0, byteSize: Int64 = 0) {
        self.needsAccessibility = needsAccessibility
        self.itemCount = itemCount
        self.byteSize = byteSize
    }
}

/// User settings (DESIGN §3.14), persisted in one `UserDefaults` suite per data directory.
///
/// Storage is key-per-field with plain property-list values, never a synthesized `Codable` blob, so a missing,
/// partial or stale value falls back to its default field by field:
/// - `units.temperature`, `units.networkRate`: raw-value strings;
/// - `popover.rows`: ordered array of `{id, visible}` dictionaries (DESIGN §3.14); unknown ids are dropped,
///   missing categories are appended visible, and at least one row stays visible;
/// - `DisabledSensors`: array of `SensorID` raw values (ARCHITECTURE §6 kill switch);
/// - `overlay.enabled` (Bool), `overlay.corner` (`OverlayCorner` raw value), `overlay.opacity` (Double, clamped
///   to `overlayOpacityRange`), `overlay.hotkey` (`{keyCode, modifiers}` Carbon ints; invalid → default);
/// - `extraDim.enabled` (Bool, default false);
/// - `clipboard.enabled` (Bool, default true), `clipboard.hotkey` (as `overlay.hotkey`; invalid → ⌘⇧V).
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
        public static let extraDimEnabled = "extraDim.enabled"
        public static let clipboardEnabled = "clipboard.enabled"
        public static let clipboardHotKey = "clipboard.hotkey"
        public static let storageIgnoredPaths = "storage.ignoredPaths"
        public static let storageLargeThreshold = "storage.largeThreshold"
        public static let storageOldThreshold = "storage.oldThreshold"
    }

    /// Extra Dim as the app sees it (spec 2026-09-24 extra dim §5.7, §7), shown under the Settings toggle.
    public enum ExtraDimStatus: Equatable, Sendable {
        /// Toggle off (or nothing reported yet).
        case off
        /// Toggle on, keyboard tap live.
        case active
        /// Toggle on, Accessibility not granted: no tap.
        case needsAccessibility
        /// Toggle on, trusted, but the event tap could not be created (retried on the next toggle-on).
        case tapFailed
        /// DisplayServices missing on this macOS: the toggle is disabled.
        case unavailable
    }

    public typealias ClipboardStatus = MonitorScreens.ClipboardStatus

    public static let overlayOpacityDefault = 0.85
    public static let overlayOpacityRange: ClosedRange<Double> = 0.4...1

    @ObservationIgnored public let defaults: UserDefaults

    /// Clears the crash-canary markers ("Disabled after a crash"). The canary owns its keys and domain
    /// (`CrashCanary.reenableAll()` in MonitorEngine); the app injects it through the runtime. Nil in renders.
    @ObservationIgnored public var reenableCrashedSensors: (@MainActor () -> Void)?

    /// Extra Dim permission state. The app re-checks `AXIsProcessTrusted()` on every call and creates the keyboard
    /// tap once trust appears (there is no trust-change notification; Settings polls it every 1 s while the toggle
    /// is on). Nil in renders → `.off`.
    @ObservationIgnored public var refreshExtraDimStatus: (@MainActor () -> ExtraDimStatus)?
    /// Opens System Settings › Privacy & Security › Accessibility. Nil in renders.
    @ObservationIgnored public var openAccessibilitySettings: (@MainActor () -> Void)?

    /// Permission and size of the clipboard history, re-read every 1 s while Settings shows the switch on.
    /// Nil in renders → no Accessibility hint, "0 items".
    @ObservationIgnored public var refreshClipboardStatus: (@MainActor () -> ClipboardStatus)?
    /// Settings "Clear history" (the app keeps pinned items). Nil in renders.
    @ObservationIgnored public var clearClipboardHistory: (@MainActor () -> Void)?

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

    // MARK: Extra Dim (spec 2026-09-24 extra dim; off by default; the dim level itself is never persisted)

    public var extraDimEnabled: Bool {
        didSet { if extraDimEnabled != oldValue { defaults.set(extraDimEnabled, forKey: Key.extraDimEnabled) } }
    }

    // MARK: Clipboard history (spec 2026-10-06 clipboard history, "Settings")

    public var clipboardEnabled: Bool {
        didSet { if clipboardEnabled != oldValue { defaults.set(clipboardEnabled, forKey: Key.clipboardEnabled) } }
    }

    public var clipboardHotKey: HotKeySpec {
        didSet {
            if clipboardHotKey != oldValue { Self.saveHotKey(clipboardHotKey, defaults, key: Key.clipboardHotKey) }
        }
    }

    // MARK: Storage (cleanup suggestions)

    /// Paths the user excluded from cleanup suggestions (stored as a sorted array of strings).
    public var storageIgnoredPaths: Set<String> {
        didSet { if storageIgnoredPaths != oldValue { defaults.set(storageIgnoredPaths.sorted(), forKey: Key.storageIgnoredPaths) } }
    }

    /// Byte thresholds for "Large & Old" (bytes, > 0); anything else stored reads as the classifier default.
    public var storageLargeThreshold: UInt64 {
        didSet { if storageLargeThreshold != oldValue { defaults.set(storageLargeThreshold, forKey: Key.storageLargeThreshold) } }
    }
    public var storageOldThreshold: UInt64 {
        didSet { if storageOldThreshold != oldValue { defaults.set(storageOldThreshold, forKey: Key.storageOldThreshold) } }
    }

    public func classifyOptions(now: Date) -> ClassifyOptions {
        ClassifyOptions(now: now, largeBytes: storageLargeThreshold, oldBytes: storageOldThreshold,
                        ignoredPaths: storageIgnoredPaths)
    }

    private static func loadBytes(_ defaults: UserDefaults, key: String, fallback: UInt64) -> UInt64 {
        guard let number = defaults.object(forKey: key) as? NSNumber, number.int64Value > 0 else { return fallback }
        return UInt64(number.int64Value)
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        storageIgnoredPaths = Set(defaults.stringArray(forKey: Key.storageIgnoredPaths) ?? [])
        storageLargeThreshold = Self.loadBytes(defaults, key: Key.storageLargeThreshold,
                                               fallback: ClassifyOptions.defaultLargeBytes)
        storageOldThreshold = Self.loadBytes(defaults, key: Key.storageOldThreshold,
                                             fallback: ClassifyOptions.defaultOldBytes)
        units = Self.loadUnits(defaults)
        popoverLayout = Self.loadPopover(defaults)
        disabledSensors = Self.loadDisabled(defaults)
        overlayEnabled = defaults.object(forKey: Key.overlayEnabled) as? Bool ?? false
        overlayCorner = defaults.string(forKey: Key.overlayCorner).flatMap(OverlayCorner.init(rawValue:)) ?? .topRight
        storedOverlayOpacity = Self.clampOpacity((defaults.object(forKey: Key.overlayOpacity) as? NSNumber)?.doubleValue)
        overlayHotKey = Self.loadHotKey(defaults)
        extraDimEnabled = defaults.object(forKey: Key.extraDimEnabled) as? Bool ?? false
        clipboardEnabled = defaults.object(forKey: Key.clipboardEnabled) as? Bool ?? true
        clipboardHotKey = Self.loadHotKey(defaults, key: Key.clipboardHotKey, fallback: .defaultClipboard)
    }

    /// `nil` → `.standard`; otherwise a suite named after the directory, so every worktree
    /// (`scripts/run.sh` sets `TELLTALE_DATA_DIR`) keeps its own settings.
    public static func defaults(for dataDirectory: URL?) -> UserDefaults {
        guard let dir = dataDirectory else { return .standard }
        return UserDefaults(suiteName: suiteName(for: dir)) ?? .standard
    }

    public static func suiteName(for dataDirectory: URL) -> String {
        "dev.warden.Warden.data-" + dataDirectoryHash(dataDirectory)
    }

    /// The same suite under the app's old bundle id (Telltale), read once by `LegacyMigration`.
    public static func legacySuiteName(for dataDirectory: URL) -> String {
        "dev.telltale.Telltale.data-" + dataDirectoryHash(dataDirectory)
    }

    private static func dataDirectoryHash(_ dataDirectory: URL) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325                        // FNV-1a, stable across launches
        for b in dataDirectory.standardizedFileURL.path.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16)
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

    static func loadHotKey(_ d: UserDefaults, key: String = Key.overlayHotKey,
                           fallback: HotKeySpec = .defaultOverlay) -> HotKeySpec {
        guard let dict = d.dictionary(forKey: key),
              let code = (dict["keyCode"] as? Int).flatMap(UInt32.init(exactly:)),
              let mods = (dict["modifiers"] as? Int).flatMap(UInt32.init(exactly:))
        else { return fallback }
        let spec = HotKeySpec(keyCode: code, modifiers: mods)
        return spec.isValid ? spec : fallback
    }

    private func saveHotKey() {
        Self.saveHotKey(overlayHotKey, defaults, key: Key.overlayHotKey)
    }

    private static func saveHotKey(_ spec: HotKeySpec, _ d: UserDefaults, key: String) {
        d.set(["keyCode": Int(spec.keyCode), "modifiers": Int(spec.modifiers)], forKey: key)
    }

    private func saveDisabled() {
        if disabledSensors.isEmpty {
            defaults.removeObject(forKey: Key.disabledSensors)
        } else {
            defaults.set(disabledSensors.map(\.rawValue).sorted(), forKey: Key.disabledSensors)
        }
    }
}
