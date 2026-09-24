import Foundation
import MonitorModel

/// The Mac shown across every artboard (History.dc.html: "MacBook Pro 14″ · M4 Pro · 8P + 4E CPU ·
/// 16-core GPU · 24 GB unified memory · up 4 d 7 h"; Memory.dc.html sub: "LPDDR5X · 273 GB/s").
enum DemoDevice {
    static func device(referenceDate: Date) -> DeviceInfo {
        DeviceInfo(
            hwModel: "Mac16,1",
            osBuild: "25A354",
            modelName: "MacBook Pro (14-inch)",
            chipName: "Apple M4 Pro",
            performanceCores: 8,
            efficiencyCores: 4,
            gpuCores: 16,
            neuralEngineCores: 16,
            memoryBytes: 24 * 1_073_741_824,
            memoryType: "LPDDR5X",
            memoryBandwidth: "273 GB/s",
            // "up 4 d 7 h" as of the reference date.
            bootTime: referenceDate.addingTimeInterval(-(4 * 86_400 + 7 * 3_600)),
            osVersion: "macOS 16.0",
            hasBattery: true,
            fanCount: 2
        )
    }
}
