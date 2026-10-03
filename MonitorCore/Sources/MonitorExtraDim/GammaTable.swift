import Foundation

/// A display transfer table (`CGGetDisplayTransferByTable` layout: three equal-length channels, values 0…1).
/// The base is captured once at the 0→1 transition; every apply writes `base × m(level)`, so ICC calibration is
/// kept and the dim never compounds (spec §4, §5.4).
public struct GammaTable: Equatable, Sendable {
    public var red: [Float]
    public var green: [Float]
    public var blue: [Float]

    /// Largest per-entry difference still treated as "our table" (spec §5.5); quantisation round-trips stay below it.
    public static let driftTolerance: Float = 1.0 / 512

    /// Channels of different lengths are truncated to the shortest.
    public init(red: [Float], green: [Float], blue: [Float]) {
        let n = min(red.count, green.count, blue.count)
        self.red = Array(red.prefix(n))
        self.green = Array(green.prefix(n))
        self.blue = Array(blue.prefix(n))
    }

    public var count: Int { red.count }

    /// Every entry of every channel × `factor`.
    public func scaled(by factor: Double) -> GammaTable {
        let f = Float(factor)
        return GammaTable(red: red.map { $0 * f }, green: green.map { $0 * f }, blue: blue.map { $0 * f })
    }

    /// The table to write at dim `level` (`self` is the captured base).
    public func dimmed(level: Int) -> GammaTable {
        scaled(by: ExtraDimCurve.multiplier(level))
    }

    /// False when the sizes differ or any entry differs by more than `tolerance` (another app wrote the table).
    public func matches(_ other: GammaTable, tolerance: Float = driftTolerance) -> Bool {
        guard count == other.count else { return false }
        for i in 0..<count {
            if abs(red[i] - other.red[i]) > tolerance || abs(green[i] - other.green[i]) > tolerance
                || abs(blue[i] - other.blue[i]) > tolerance {
                return false
            }
        }
        return true
    }
}
