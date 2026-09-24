import Foundation
import MonitorModel

// W0b stub (ARCHITECTURE §5.6). W1 replaces this file.

public struct FrameAssembler {
    public init(resolver: any AppResolving, energy: any EnergyAttributor = RulingEnergyAttributor(), currentUID: uid_t = getuid()) {}
    /// Alert/events filled by caller.
    public mutating func assemble(_ tick: RawTick, inspectedApp: AppKey?) -> SystemFrame {
        SystemFrame(wallTime: tick.wallTime, uptimeNs: tick.uptimeNs, mode: tick.mode)
    }
    public mutating func reset() {}
}
