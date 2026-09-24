import SwiftUI
import Testing
@testable import MonitorUIKit

@Suite struct TokenTests {
    static let surfaces: [UInt32] = [TTHex.bgWindow, TTHex.bgHeader, TTHex.bgCard, TTHex.bgSidebar, TTHex.bgPopover,
                                     TTHex.bgElevated]

    @Test(arguments: surfaces)
    func textContrastOnSurfaces(surface: UInt32) {
        #expect(TTHex.contrast(TTHex.textPrimary, surface) >= 4.5)
        #expect(TTHex.contrast(TTHex.textSecondary, surface) >= 4.5)
        #expect(TTHex.contrast(TTHex.textTertiary, surface) >= 4.5)
    }

    @Test func contrastMath() {
        #expect(abs(TTHex.contrast(0xFFFFFF, 0x000000) - 21) < 0.01)
        #expect(TTHex.contrast(0x777777, 0x777777) == 1)
    }

    @Test func tileIndexIsStableFNV1a() {
        // FNV-1a 32 of "" is the offset basis 0x811C9DC5 → mod 8 = 5.
        #expect(TTColor.tileIndex(for: "") == Int(0x811C_9DC5 % 8))
        #expect(TTColor.tileIndex(for: "com.apple.dt.Xcode") == TTColor.tileIndex(for: "com.apple.dt.Xcode"))
        let spread = Set(["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"].map(TTColor.tileIndex(for:)))
        #expect(spread.count > 3)
    }

    @Test func iconPathsStayInsideTheGrid() {
        for name in TTIconName.allCases {
            let bounds = TTIconPaths.all[name]!.boundingRect
            #expect(!bounds.isEmpty || bounds.width > 0 || bounds.height > 0, "\(name) empty")
            #expect(bounds.minX >= 0.9 && bounds.maxX <= 15.1 && bounds.minY >= 0.9 && bounds.maxY <= 15.1,
                    "\(name) bounds \(bounds)")
        }
    }

    @Test func svgArcMatchesCircle() {
        // Half circle from (0,8) to (16,8), radius 8, sweep 1 → passes through (8,0) (y-down, clockwise).
        let path = SVGPath.parse("M0 8A8 8 0 0 1 16 8")
        let b = path.boundingRect
        #expect(abs(b.minY - 0) < 0.05)
        #expect(abs(b.maxY - 8) < 0.05)
        #expect(abs(b.width - 16) < 0.05)
    }

    @Test func svgRelativeCommands() {
        let b = SVGPath.parse("M2 2h4v4h-4z").boundingRect
        #expect(b == CGRect(x: 2, y: 2, width: 4, height: 4))
        let c = SVGPath.parse("M5 3l2.5 2.5").boundingRect
        #expect(c == CGRect(x: 5, y: 3, width: 2.5, height: 2.5))
        // Leading-dot numbers and implicit repeats: "s5.5-.9 5.5-2".
        let d = SVGPath.parse("M2.5 12c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2").boundingRect
        #expect(abs(d.maxX - 13.5) < 0.01)
    }
}
