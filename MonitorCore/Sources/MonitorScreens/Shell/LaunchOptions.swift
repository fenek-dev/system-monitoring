import Foundation
import MonitorMocks
import MonitorModel

/// Launch arguments and environment (ARCHITECTURE §5.11). Parsed here (testable); `App/Composition` applies them.
///
///     --mock <scenario> | TELLTALE_MOCK=<scenario>     mock runtime (unknown/missing scenario → calm)
///     --open-dashboard [page]                           open the dashboard at launch (default overview)
///     --open-popover                                    open the popover at launch
///     --open-settings                                   open Settings at launch (verification aid)
///     --crash-sensor <id>                               DEBUG canary drill (ignored in Release by the app)
///     --status-preview elevated|critical                DEBUG: status item shows a thermals alert (critical pulses)
///     TELLTALE_DATA_DIR=<dir>                           store + settings suite per data dir
///     TELLTALE_DISABLE_SENSORS=coalitions,soc,…         kill switch (merged with defaults "DisabledSensors")
public struct LaunchOptions: Sendable, Equatable {
    public var mockScenario: MockScenario?
    public var openDashboard: DashboardPage?
    public var openPopover = false
    public var openSettings = false
    public var crashSensor: SensorID?
    public var statusPreview: AlertLevel?
    public var dataDirectory: URL?
    public var disabledSensors: Set<SensorID> = []

    public init(mockScenario: MockScenario? = nil, openDashboard: DashboardPage? = nil, openPopover: Bool = false,
                openSettings: Bool = false, crashSensor: SensorID? = nil, dataDirectory: URL? = nil,
                disabledSensors: Set<SensorID> = []) {
        self.mockScenario = mockScenario
        self.openDashboard = openDashboard
        self.openPopover = openPopover
        self.openSettings = openSettings
        self.crashSensor = crashSensor
        self.dataDirectory = dataDirectory
        self.disabledSensors = disabledSensors
    }

    /// `arguments` excludes nothing: a leading executable path is skipped because it never matches a flag.
    public static func parse(arguments: [String], environment: [String: String]) -> LaunchOptions {
        var o = LaunchOptions()
        if let m = environment["TELLTALE_MOCK"] { o.mockScenario = MockScenario(rawValue: m) ?? .calm }
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
            case "--open-dashboard":
                o.openDashboard = next().flatMap(DashboardPage.init(rawValue:)) ?? .overview
            case "--open-popover":
                o.openPopover = true
            case "--open-settings":
                o.openSettings = true
            case "--crash-sensor":
                o.crashSensor = next().flatMap(SensorID.init(rawValue:))
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
