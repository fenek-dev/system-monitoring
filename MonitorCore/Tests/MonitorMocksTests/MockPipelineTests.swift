import Foundation
import Testing
import MonitorModel
@testable import MonitorMocks

/// Tests `MockFeeder`, the interval/pause state machine `MockPipeline` (`MonitorRuntime`) drives with a
/// real timer `Task`. Kept here (not a `MonitorRuntimeTests` suite, which W7 owns) so it runs
/// synchronously with no `LiveModel`/timer involved — see `MockFeeder`'s doc comment.
@Suite struct MockPipelineTests {
    @MainActor
    @Test func defaultsToBackgroundFiveSeconds() {
        let feeder = MockFeeder(provider: MockDataProvider(scenario: .calm))
        #expect(feeder.mode == .background)
        #expect(feeder.interval == .seconds(5))
    }

    @MainActor
    @Test func popoverOrDashboardVisibleIsOneSecond() {
        let feeder = MockFeeder(provider: MockDataProvider(scenario: .calm))
        feeder.setVisibility(UIVisibility(popoverOpen: true))
        #expect(feeder.interval == .seconds(1))

        feeder.setVisibility(UIVisibility(dashboardVisible: true))
        #expect(feeder.interval == .seconds(1))

        feeder.setVisibility(UIVisibility())
        #expect(feeder.interval == .seconds(5))
    }

    @MainActor
    @Test func pausedTakesNoSamples() {
        let feeder = MockFeeder(provider: MockDataProvider(scenario: .calm))
        feeder.setVisibility(UIVisibility(popoverOpen: true))
        feeder.setPaused(true)
        #expect(feeder.interval == nil)
        #expect(feeder.nextFrame() == nil)
        #expect(feeder.tick == 0)   // no tick consumed while paused
    }

    @MainActor
    @Test func unpausingResumesTheCurrentModesInterval() {
        let feeder = MockFeeder(provider: MockDataProvider(scenario: .calm))
        feeder.setVisibility(UIVisibility(dashboardVisible: true))
        feeder.setPaused(true)
        feeder.setPaused(false)
        #expect(feeder.interval == .seconds(1))
        #expect(feeder.nextFrame() != nil)
        #expect(feeder.tick == 1)
    }

    @MainActor
    @Test func ticksAdvanceSequentiallyAndDeterministically() {
        let a = MockFeeder(provider: MockDataProvider(scenario: .calm, seed: 9))
        let b = MockFeeder(provider: MockDataProvider(scenario: .calm, seed: 9))
        let framesA = (0..<5).compactMap { _ in a.nextFrame() }
        let framesB = (0..<5).compactMap { _ in b.nextFrame() }
        #expect(a.tick == 5)
        #expect(framesA == framesB)
        // Frames actually differ tick to tick (the LCG is moving), not five copies of the same frame.
        #expect(Set(framesA.map(\.wallTime)).count == 5)
    }
}
