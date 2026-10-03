import Foundation
import Testing
@testable import MonitorExtraDim

@Suite struct ExtraDimCurveTests {
    @Test func endpoints() {
        #expect(ExtraDimCurve.multiplier(0) == 1)
        #expect(ExtraDimCurve.luminance(0) == 1)
        #expect(abs(ExtraDimCurve.multiplier(8) - 0.351) <= 0.001)
        #expect(abs(ExtraDimCurve.luminance(8) - 0.10) < 1e-12)
    }

    @Test func specTable() {
        let m: [Int: Double] = [1: 0.878, 2: 0.770, 4: 0.592, 6: 0.456]
        for (n, v) in m { #expect(abs(ExtraDimCurve.multiplier(n) - v) <= 0.001, "m(\(n))") }
    }

    @Test func strictlyDecreasing() {
        for n in 0..<ExtraDimCurve.steps {
            #expect(ExtraDimCurve.multiplier(n + 1) < ExtraDimCurve.multiplier(n))
            #expect(ExtraDimCurve.luminance(n + 1) < ExtraDimCurve.luminance(n))
        }
    }

    @Test func constantLuminanceRatio() {
        let r = ExtraDimCurve.luminance(1) / ExtraDimCurve.luminance(0)
        for n in 1..<ExtraDimCurve.steps {
            #expect(abs(ExtraDimCurve.luminance(n + 1) / ExtraDimCurve.luminance(n) - r) < 1e-12)
        }
    }

    @Test func clampsOutOfRange() {
        #expect(ExtraDimCurve.multiplier(-1) == 1)
        #expect(ExtraDimCurve.multiplier(9) == ExtraDimCurve.multiplier(8))
    }
}

@Suite struct GammaTableTests {
    static let base = GammaTable(red: [0, 0.25, 0.5, 1], green: [0, 0.2, 0.6, 0.98], blue: [0.01, 0.3, 0.7, 0.95])

    @Test func scalingPreservesPerEntryRatios() {
        let base = Self.base
        let dimmed = base.dimmed(level: 4)
        let m = Float(ExtraDimCurve.multiplier(4))
        for i in 0..<base.count {
            #expect(abs(dimmed.red[i] - base.red[i] * m) < 1e-6)
            #expect(abs(dimmed.green[i] - base.green[i] * m) < 1e-6)
            #expect(abs(dimmed.blue[i] - base.blue[i] * m) < 1e-6)
            if i > 0 { #expect(abs(dimmed.red[i] / dimmed.red[1] - base.red[i] / base.red[1]) < 1e-5) }
        }
        #expect(base.dimmed(level: 0) == base)
    }

    @Test func driftToleranceAcceptsHalfAndRejectsDouble() {
        let base = Self.base
        let small: Float = 1.0 / 1024
        let large: Float = 1.0 / 256
        #expect(base.matches(GammaTable(red: base.red.map { $0 + small }, green: base.green, blue: base.blue)))
        #expect(base.matches(GammaTable(red: base.red, green: base.green.map { $0 - small }, blue: base.blue)))
        var drifted = base
        drifted.blue[2] += large
        #expect(!base.matches(drifted))
        drifted = base
        drifted.green[0] -= large
        #expect(!base.matches(drifted))
    }

    @Test func sizeMismatchIsDrift() {
        let base = Self.base
        #expect(!base.matches(GammaTable(red: [0, 1], green: [0, 1], blue: [0, 1])))
    }

    @Test func unequalChannelsTruncate() {
        #expect(GammaTable(red: [0, 1, 2], green: [0, 1], blue: [0, 1, 2]).count == 2)
    }
}
