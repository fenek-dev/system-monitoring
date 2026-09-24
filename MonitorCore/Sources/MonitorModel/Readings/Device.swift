import Foundation

public struct DeviceInfo: Sendable, Codable, Equatable {
    /// "MacBookPro18,2" (catalog key).
    public var hwModel: String
    public var osBuild: String
    public var modelName: String, chipName: String
    public var performanceCores: Int, efficiencyCores: Int, gpuCores: Int?, neuralEngineCores: Int?
    public var memoryBytes: UInt64, memoryType: String?, memoryBandwidth: String?
    public var bootTime: Date, osVersion: String, hasBattery: Bool, fanCount: Int

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
        hasBattery: Bool = false,
        fanCount: Int = 0
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

    /// Neutral device shown before the `device` sensor has run.
    public static let placeholder = DeviceInfo(modelName: "Mac", chipName: "Apple Silicon")
}
