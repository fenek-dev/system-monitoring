import MonitorSnapshotTesting
import SwiftUI
import Testing
@testable import MonitorUIKit

/// Goldens of `TTExtraDimHUD` per state, on a dark canvas with margin for the popover shadow.
@MainActor @Suite struct ExtraDimHUDSnapshotTests {
    nonisolated static let cases: [(String, TTExtraDimHUD.Content)] = [
        ("level-0", .level(0)), ("level-4", .level(4)), ("level-8", .level(8)),
        ("reset-by-other-app", .resetByOtherApp), ("cannot-dim", .cannotDim),
    ]

    @Test(arguments: cases.map(\.0))
    func hud(name: String) throws {
        let content = try #require(Self.cases.first { $0.0 == name }?.1)
        let view = TTExtraDimHUD(content)
            .frame(width: 320, height: 130)
            .background(TTColor.bgWindow)
        assertSnapshot(view, size: CGSize(width: 320, height: 130), named: "component-extra-dim-hud-\(name)")
    }
}
