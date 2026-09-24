import Foundation
import MonitorModel

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file (DESIGN §5 formatting rules; pure; nil → "—").

public enum TTFormat {
    public static func percent(_ fraction: Double?, digits: Int = 0) -> String { "—" }
    public static func cpuPercent(_ p: Double?) -> String { "—" }
    public static func bytes(_ b: UInt64?) -> String { "—" }
    public static func rate(_ bps: Double?, units: UnitPreferences) -> String { "—" }
    public static func temperature(_ c: Double?, units: UnitPreferences) -> String { "—" }
    public static func watts(_ w: Double?, digits: Int = 1) -> String { "—" }
    public static func frequency(_ mhz: Double?) -> String { "—" }
    public static func duration(_ d: Duration?) -> String { "—" }
    public static func cpuTime(_ ns: UInt64?) -> String { "—" }
    public static func count(_ n: Int?) -> String { "—" }
    public static func rpm(_ r: Double?) -> String { "—" }
}
