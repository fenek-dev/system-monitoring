import Foundation
import MonitorModel

/// P-state → MHz tables per chip (`SoC/Resources/pstates.json`, keyed by `hw.model`).
/// Tables list the ACTIVE states in IOReport order (the idle `OFF`/`IDLE`/`DOWN` state is not in the table).
struct PStateTables: Codable, Sendable, Equatable {
    var ecpuMHz: [Double]
    var pcpuMHz: [Double]
    /// nil: GPU residency states don't map to a known frequency table on this chip.
    var gpuMHz: [Double]?
}

struct PStateCatalog: Codable, Sendable, Equatable {
    var version: Int
    var chips: [String: PStateTables]
    /// hw.model → chip key.
    var models: [String: String]

    /// nil for unknown chips (MHz fields stay nil; ARCHITECTURE §5.3).
    func tables(forModel model: String) -> PStateTables? {
        models[model].flatMap { chips[$0] }
    }

    static func bundled() throws(SensorError) -> PStateCatalog {
        try w6bLoadResource("pstates", as: PStateCatalog.self)
    }
}
