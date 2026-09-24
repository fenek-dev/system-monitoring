import AppKit
import Foundation
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// Regression: text laid out by a non-snapshot path BEFORE any `configureTextRendering()` call must not drift goldens
/// (font smoothing latches at the process's first text layout). Meaningful when run alone
/// (`--filter TextRenderingOrderTests`), where this is the process's first text layout; harmless in full runs.
@MainActor
@Suite("TextRenderingOrderTests")
struct TextRenderingOrderTests {
    @Test func textLaidOutBeforeConfigureDoesNotDriftGoldens() {
        #expect(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["AppleFontSmoothing"] as? Int == 0)
        _ = NSApplication.shared
        let field = NSTextField(labelWithString: "Laid out first 123")
        field.font = .systemFont(ofSize: 13)
        field.sizeToFit()
        if let rep = field.bitmapImageRepForCachingDisplay(in: field.bounds) {
            field.cacheDisplay(in: field.bounds, to: rep)
        }
        let canvas = CGSize(width: 360, height: 60)
        let ctx = ScreenCatalog.context(for: .calm, page: .overview, ticks: 60) // no ScreenFixture: it configures
        assertSnapshot(OverlayView()
                           .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                           .telltaleEnvironment(ctx),
                       size: canvas, named: "overlay-calm")
    }
}
