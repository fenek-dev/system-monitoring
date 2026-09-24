import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// Overlay fixtures shared by the logic and snapshot suites.
@MainActor
enum OverlayFixture {
    static let gpuDown = "IOReport GPU channels not found"

    /// Calm frames 0…60 with the GPU gone: `gpu.usage` nil and both GPU sources unavailable.
    static func gpuUnavailableLive() -> LiveModel {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.gpu.usage = nil
            f.sensorHealth[.soc] = .unavailable(gpuDown)
            f.sensorHealth[.gpuClients] = .unavailable(gpuDown)
            live.apply(f)
        }
        live.isPresenting = true
        return live
    }

    static func gpuUnavailableContext() -> ShellContext {
        var ctx = ScreenFixture.context(.calm)
        ctx.live = gpuUnavailableLive()
        return ctx
    }
}

/// Spec 2026-09-25 overlay §UI goldens (`__Snapshots__/overlay-*.png`), dark, en_US/London.
@MainActor
@Suite("OverlaySnapshotTests")
struct OverlaySnapshotTests {
    static let canvas = CGSize(width: 360, height: 60)

    private func snap(_ ctx: ShellContext, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        assertSnapshot(OverlayView()
                           .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .topLeading)
                           .telltaleEnvironment(ctx),
                       size: Self.canvas, named: "overlay-\(name)", sourceLocation: sourceLocation)
    }

    @Test func calm() { snap(ScreenFixture.context(.calm), "calm") }
    @Test func memoryWarning() { snap(ScreenFixture.context(.memoryWarning), "memoryWarning") }
    @Test func memoryCritical() { snap(ScreenFixture.context(.memoryCritical), "memoryCritical") }
    @Test func unavailable() { snap(OverlayFixture.gpuUnavailableContext(), "unavailable") }
    @Test func collecting() { snap(ScreenFixture.context(.collecting), "collecting") }
}
