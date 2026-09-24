import Foundation

public struct MemorySnapshot: Sendable, Codable, Equatable {
    public var total: UInt64, used: UInt64?, appMemory: UInt64?, wired: UInt64?, compressed: UInt64?
    public var cachedFiles: UInt64?, free: UInt64?, compressionRatio: Double?
    public var pressureLevel: MemoryPressureLevel?, pressureFraction: Double?
    public var swapUsed: UInt64?, swapTotal: UInt64?, swapFileCount: Int?
    public var pageInsPerSec: Double?, pageOutsPerSec: Double?, swapInsPerSec: Double?, swapOutsPerSec: Double?

    public init(
        total: UInt64 = 0,
        used: UInt64? = nil,
        appMemory: UInt64? = nil,
        wired: UInt64? = nil,
        compressed: UInt64? = nil,
        cachedFiles: UInt64? = nil,
        free: UInt64? = nil,
        compressionRatio: Double? = nil,
        pressureLevel: MemoryPressureLevel? = nil,
        pressureFraction: Double? = nil,
        swapUsed: UInt64? = nil,
        swapTotal: UInt64? = nil,
        swapFileCount: Int? = nil,
        pageInsPerSec: Double? = nil,
        pageOutsPerSec: Double? = nil,
        swapInsPerSec: Double? = nil,
        swapOutsPerSec: Double? = nil
    ) {
        self.total = total
        self.used = used
        self.appMemory = appMemory
        self.wired = wired
        self.compressed = compressed
        self.cachedFiles = cachedFiles
        self.free = free
        self.compressionRatio = compressionRatio
        self.pressureLevel = pressureLevel
        self.pressureFraction = pressureFraction
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.swapFileCount = swapFileCount
        self.pageInsPerSec = pageInsPerSec
        self.pageOutsPerSec = pageOutsPerSec
        self.swapInsPerSec = swapInsPerSec
        self.swapOutsPerSec = swapOutsPerSec
    }
}
