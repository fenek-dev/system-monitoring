import Foundation

public enum MemoryPressureLevel: Int, Sendable, Codable, Comparable {
    case normal = 1, warning = 2, critical = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct MemoryReading: Sendable, Codable {
    public var pageSize: UInt64, total: UInt64
    public var free, active, inactive, speculative, wired, purgeable, fileBacked, anonymous: UInt64
    public var compressorBytes: UInt64, compressedOriginalBytes: UInt64?
    public var pageins, pageouts, swapins, swapouts: UInt64
    public var swapTotal, swapUsed: UInt64, swapFileCount: Int?
    public var pressureLevel: MemoryPressureLevel?, pressureFraction: Double?

    public init(
        pageSize: UInt64 = 0,
        total: UInt64 = 0,
        free: UInt64 = 0,
        active: UInt64 = 0,
        inactive: UInt64 = 0,
        speculative: UInt64 = 0,
        wired: UInt64 = 0,
        purgeable: UInt64 = 0,
        fileBacked: UInt64 = 0,
        anonymous: UInt64 = 0,
        compressorBytes: UInt64 = 0,
        compressedOriginalBytes: UInt64? = nil,
        pageins: UInt64 = 0,
        pageouts: UInt64 = 0,
        swapins: UInt64 = 0,
        swapouts: UInt64 = 0,
        swapTotal: UInt64 = 0,
        swapUsed: UInt64 = 0,
        swapFileCount: Int? = nil,
        pressureLevel: MemoryPressureLevel? = nil,
        pressureFraction: Double? = nil
    ) {
        self.pageSize = pageSize
        self.total = total
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.purgeable = purgeable
        self.fileBacked = fileBacked
        self.anonymous = anonymous
        self.compressorBytes = compressorBytes
        self.compressedOriginalBytes = compressedOriginalBytes
        self.pageins = pageins
        self.pageouts = pageouts
        self.swapins = swapins
        self.swapouts = swapouts
        self.swapTotal = swapTotal
        self.swapUsed = swapUsed
        self.swapFileCount = swapFileCount
        self.pressureLevel = pressureLevel
        self.pressureFraction = pressureFraction
    }
}
