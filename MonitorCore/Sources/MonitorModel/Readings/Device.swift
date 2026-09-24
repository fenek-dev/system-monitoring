import Foundation

public struct DeviceInfo: Sendable, Codable, Equatable {
    /// "MacBookPro18,2" (catalog key).
    public var hwModel: String
    public var osBuild: String
    public var modelName: String, chipName: String
    public var performanceCores: Int, efficiencyCores: Int, gpuCores: Int?, neuralEngineCores: Int?
    public var memoryBytes: UInt64, memoryType: String?, memoryBandwidth: String?
    public var bootTime: Date, osVersion: String
    /// nil = not known yet (placeholder before the `device` sensor ran). Never shown as a fact while nil (U-I2).
    public var hasBattery: Bool?
    /// SMC `FNum`; nil = unknown (SMC unreachable, or before the `device` sensor ran). 0 = this Mac has no fans.
    public var fanCount: Int?

    public init(
        hwModel: String = "",
        osBuild: String = "",
        modelName: String = "",
        chipName: String = "",
        performanceCores: Int = 0,
        efficiencyCores: Int = 0,
        gpuCores: Int? = nil,
        neuralEngineCores: Int? = nil,
        memoryBytes: UInt64 = 0,
        memoryType: String? = nil,
        memoryBandwidth: String? = nil,
        bootTime: Date = Date(timeIntervalSince1970: 0),
        osVersion: String = "",
        hasBattery: Bool? = nil,
        fanCount: Int? = nil
    ) {
        self.hwModel = hwModel
        self.osBuild = osBuild
        self.modelName = modelName
        self.chipName = chipName
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.gpuCores = gpuCores
        self.neuralEngineCores = neuralEngineCores
        self.memoryBytes = memoryBytes
        self.memoryType = memoryType
        self.memoryBandwidth = memoryBandwidth
        self.bootTime = bootTime
        self.osVersion = osVersion
        self.hasBattery = hasBattery
        self.fanCount = fanCount
    }

    /// Neutral device shown before the `device` sensor has run (battery and fans unknown).
    public static let placeholder = DeviceInfo(modelName: "Mac", chipName: "Apple Silicon")
}
