import Foundation
import MonitorMocks
import MonitorModel

/// Launch arguments and environment (ARCHITECTURE §5.11). Parsed here (testable); `App/Composition` applies them.
///
///     --mock <scenario> | TELLTALE_MOCK=<scenario>     mock runtime (unknown/missing scenario → calm)
///     --mock-storage <empty|scanning|map|cleanup|noFDA> | TELLTALE_MOCK_STORAGE   Storage mock state (unknown/missing → map)
///     --open-dashboard [page]                          open the dashboard at launch (default overview)
///     --open-popover                                    open the popover at launch
///     --open-settings                                   open Settings at launch (verification aid)
///     --overlay                                         show the stats overlay this run (not persisted)
///     --crash-sensor <id>                               DEBUG canary drill (ignored in Release by the app)
///     --status-preview elevated|critical                DEBUG: status item shows a thermals alert (critical pulses)
///     --login-item register|unregister|status           launch-at-login CLI check: prints SMAppService status, exits
///     TELLTALE_DATA_DIR=<dir>                           store + settings suite per data dir
///     TELLTALE_DISABLE_SENSORS=coalitions,soc,…         kill switch (merged with defaults "DisabledSensors")
public struct LaunchOptions: Sendable, Equatable {
    public var mockScenario: MockScenario?
    /// `--mock-storage`: Storage fixture state in mock mode (ignored live).
    public var mockStorage: MockStorageState.Kind?
    public var openDashboard: DashboardPage?
    public var openPopover = false
    public var openSettings = false
    /// `--overlay`: show the overlay for this run without persisting `overlayEnabled` (perf scenario).
    public var overlay = false
    public var crashSensor: SensorID?
    public var statusPreview: AlertLevel?
    /// `--login-item register|unregister|status`: act on `SMAppService.mainApp`, print the status, exit.
    public var loginItemCommand: String?
    public var dataDirectory: URL?
    public var disabledSensors: Set<SensorID> = []

    public init(mockScenario: MockScenario? = nil, openDashboard: DashboardPage? = nil, openPopover: Bool = false,
                openSettings: Bool = false, overlay: Bool = false, crashSensor: SensorID? = nil,
                statusPreview: AlertLevel? = nil, dataDirectory: URL? = nil, disabledSensors: Set<SensorID> = []) {
        self.mockScenario = mockScenario
        self.openDashboard = openDashboard
        self.openPopover = openPopover
        self.openSettings = openSettings
        self.overlay = overlay
        self.crashSensor = crashSensor
        self.statusPreview = statusPreview
        self.dataDirectory = dataDirectory
        self.disabledSensors = disabledSensors
    }

    /// `arguments` excludes nothing: a leading executable path is skipped because it never matches a flag.
    public static func parse(arguments: [String], environment: [String: String]) -> LaunchOptions {
        var o = LaunchOptions()
        if let m = environment["TELLTALE_MOCK"] { o.mockScenario = MockScenario(rawValue: m) ?? .calm }
        if let m = environment["TELLTALE_MOCK_STORAGE"] { o.mockStorage = MockStorageState.Kind(rawValue: m) ?? .map }
        if let d = environment["TELLTALE_DATA_DIR"], !d.isEmpty {
            o.dataDirectory = URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let s = environment["TELLTALE_DISABLE_SENSORS"] { o.disabledSensors = parseSensorList(s) }

        var i = 0
        func next() -> String? {
            guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else { return nil }
            i += 1
            return arguments[i]
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--mock":
                o.mockScenario = next().flatMap(MockScenario.init(rawValue:)) ?? .calm
            case "--mock-storage":
                o.mockStorage = next().flatMap(MockStorageState.Kind.init(rawValue:)) ?? .map
            case "--open-dashboard":
                o.openDashboard = next().flatMap(DashboardPage.init(rawValue:)) ?? .overview
            case "--open-popover":
                o.openPopover = true
            case "--open-settings":
                o.openSettings = true
            case "--overlay":
                o.overlay = true
            case "--crash-sensor":
                o.crashSensor = next().flatMap(SensorID.init(rawValue:))
            case "--login-item":
                let cmd = next()                                    // never a following "--flag"
                o.loginItemCommand = ["register", "unregister"].contains(cmd) ? cmd : "status"
            case "--status-preview":
                o.statusPreview = next() == "critical" ? .critical : .elevated
            default:
                break
            }
            i += 1
        }
        return o
    }

    /// Comma/space separated sensor ids; unknown ids are ignored.
    public static func parseSensorList(_ s: String) -> Set<SensorID> {
        Set(s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { SensorID(rawValue: String($0)) })
    }
}
