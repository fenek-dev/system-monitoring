import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

/// Overlay fixtures shared by the logic and snapshot suites. Every model presents at `.overlay`, as the App does
/// while only the overlay is visible, so the goldens prove the overlay needs nothing `.overlay` does not publish.
@MainActor
enum OverlayFixture {
    static let gpuDown = "IOReport GPU channels not found"

    static func live(_ scenario: MockScenario) -> LiveModel { .mock(scenario, presentation: .overlay) }

    static func context(_ scenario: MockScenario) -> ShellContext {
        var ctx = ScreenFixture.context(scenario)
        ctx.live = live(scenario)
        return ctx
    }

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
        live.presentation = .overlay
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

    @Test func calm() { snap(OverlayFixture.context(.calm), "calm") }
    @Test func memoryWarning() { snap(OverlayFixture.context(.memoryWarning), "memoryWarning") }
    @Test func memoryCritical() { snap(OverlayFixture.context(.memoryCritical), "memoryCritical") }
    @Test func unavailable() { snap(OverlayFixture.gpuUnavailableContext(), "unavailable") }
    @Test func collecting() { snap(OverlayFixture.context(.collecting), "collecting") }
    /// Sampling paused: the whole overlay dims to 50 %.
    @Test func paused() { snap(OverlayFixture.context(.paused), "paused") }

    /// Ruling (width jitter): the overlay keeps one size whatever the values: calm, collecting ("—"),
    /// GPU unavailable ("— — —") and worst-case values (100 %, 999.9 GB) all fit the same frame.
    @Test func sizeIsStableAcrossValues() {
        // Before any NSHostingView: AppKit latches font smoothing at first text draw (would skew the goldens).
        SnapshotRenderer.configureTextRendering()
        func size(_ ctx: ShellContext) -> CGSize {
            TTFormat.$locale.withValue(Locale(identifier: "en_US")) {
                NSHostingView(rootView: OverlayView().telltaleEnvironment(ctx)).fittingSize
            }
        }
        let calm = size(OverlayFixture.context(.calm))
        #expect(calm.width > 0 && calm.height > 0)
        #expect(size(OverlayFixture.context(.collecting)) == calm)
        #expect(size(OverlayFixture.gpuUnavailableContext()) == calm)
        #expect(size(OverlayFixture.extremeContext()) == calm)
        #expect(calm.width <= Self.canvas.width && calm.height <= Self.canvas.height)
    }
}

extension OverlayFixture {
    /// Worst-case values: CPU and GPU pinned at 100 %, memory ~999.9 GB.
    static func extremeContext() -> ShellContext {
        let provider = MockDataProvider(scenario: .calm)
        let live = LiveModel(device: provider.device)
        for tick in 0...60 {
            var f = provider.frame(at: tick)
            f.cpu.usage = 1
            f.gpu.usage = 1
            f.memory.used = 1_073_634_000_000   // 999.9 GiB
            live.apply(f)
        }
        live.presentation = .overlay
        var ctx = ScreenFixture.context(.calm)
        ctx.live = live
        return ctx
    }
}
