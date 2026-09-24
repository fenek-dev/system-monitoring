import CoreGraphics
import Foundation
import MonitorModel
@testable import MonitorScreens
import Testing

/// Overlay pure helpers (spec 2026-09-25 overlay §Stats, §Window): stats, placement, display choice.
@Suite("OverlayLogicTests")
struct OverlayLogicTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func points(_ values: [Double?], step: TimeInterval = 1) -> [SeriesPoint] {
        values.enumerated().map { SeriesPoint(time: t0.addingTimeInterval(Double($0.offset) * step), value: $0.element) }
    }

    // MARK: - OverlayStats

    @Test func statsNeedTwoSamples() {
        #expect(OverlayStats.compute([], now: t0) == nil)
        #expect(OverlayStats.compute(points([42]), now: t0) == nil)
        #expect(OverlayStats.compute(points([nil, 5, nil]), now: t0.addingTimeInterval(2)) == nil)
    }

    @Test func statsSkipGapsAndWeighByTime() throws {
        // 10 → 20: 1 s; 20 → 30 (nil between): 2 s; 30 is last: 1 s. (10 + 40 + 30) / 4 = 20.
        let s = try #require(OverlayStats.compute(points([10, 20, nil, 30]), now: t0.addingTimeInterval(3)))
        #expect(s.min == 10)
        #expect(s.max == 30)
        #expect(abs(s.avg - 20) < 1e-9)
        // Uneven weights: 10 → 40 (2 s), 40 last (1 s): (20 + 40) / 3 = 20; unweighted would be 25.
        let u = try #require(OverlayStats.compute(points([10, nil, 40]), now: t0.addingTimeInterval(2)))
        #expect(abs(u.avg - 20) < 1e-9)
    }

    @Test func statsCapLongGapsAtFiveSeconds() throws {
        // 10 held 20 s before 40 → weight 5 (cap); 40 last → 1. (50 + 40) / 6 = 15.
        let pts = [SeriesPoint(time: t0, value: 10), SeriesPoint(time: t0.addingTimeInterval(20), value: 40)]
        let s = try #require(OverlayStats.compute(pts, now: t0.addingTimeInterval(20)))
        #expect(abs(s.avg - 15) < 1e-9)
        #expect(s.min == 10 && s.max == 40)
    }

    @Test func statsExcludePointsOutsideWindow() throws {
        // 0 s: 99 (older than 60 s at now = 70 s), then 1, 3 at 65 / 70 s.
        let pts = [SeriesPoint(time: t0, value: 99), SeriesPoint(time: t0.addingTimeInterval(65), value: 1),
                   SeriesPoint(time: t0.addingTimeInterval(70), value: 3),
                   SeriesPoint(time: t0.addingTimeInterval(80), value: 500)]   // after now: excluded
        let s = try #require(OverlayStats.compute(pts, now: t0.addingTimeInterval(70)))
        #expect(s.min == 1 && s.max == 3)
        // 1 held 5 s, 3 last 1 s: (5 + 3) / 6.
        #expect(abs(s.avg - 8.0 / 6) < 1e-9)
        #expect(OverlayStats.compute(pts, window: .seconds(4), now: t0.addingTimeInterval(70)) == nil)
    }

    @Test func statsAcrossCadenceChange() throws {
        // 5-s cadence then 1-s: 10 @0, 20 @5, 30 @6, 40 @7. Weights 5, 1, 1, 1 → (50+20+30+40)/8 = 17.5.
        let pts = [SeriesPoint(time: t0, value: 10), SeriesPoint(time: t0.addingTimeInterval(5), value: 20),
                   SeriesPoint(time: t0.addingTimeInterval(6), value: 30), SeriesPoint(time: t0.addingTimeInterval(7), value: 40)]
        let s = try #require(OverlayStats.compute(pts, now: t0.addingTimeInterval(7)))
        #expect(abs(s.avg - 17.5) < 1e-9)
    }

    // MARK: - OverlayPlacement.frame

    @Test func frameCorners() {
        let vf = CGRect(x: 0, y: 0, width: 1512, height: 944)
        let size = CGSize(width: 300, height: 44)
        #expect(OverlayPlacement.frame(size: size, visibleFrame: vf, corner: .topRight).origin == CGPoint(x: 1204, y: 892))
        #expect(OverlayPlacement.frame(size: size, visibleFrame: vf, corner: .topLeft).origin == CGPoint(x: 8, y: 892))
        #expect(OverlayPlacement.frame(size: size, visibleFrame: vf, corner: .bottomLeft).origin == CGPoint(x: 8, y: 8))
        #expect(OverlayPlacement.frame(size: size, visibleFrame: vf, corner: .bottomRight).origin == CGPoint(x: 1204, y: 8))
        for c in OverlayCorner.allCases {
            #expect(OverlayPlacement.frame(size: size, visibleFrame: vf, corner: c).size == size)
        }
    }

    @Test func frameRespectsMenuBarInsetAndNegativeOrigin() {
        // visibleFrame already excludes the menu bar / notch: top edge is visibleFrame.maxY.
        let notch = CGRect(x: 0, y: 0, width: 1512, height: 982 - 38)
        #expect(OverlayPlacement.frame(size: CGSize(width: 300, height: 44), visibleFrame: notch, corner: .topRight).maxY
                == notch.maxY - 8)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let size = CGSize(width: 300, height: 44)
        #expect(OverlayPlacement.frame(size: size, visibleFrame: left, corner: .topLeft).origin == CGPoint(x: -1912, y: 1028))
        #expect(OverlayPlacement.frame(size: size, visibleFrame: left, corner: .bottomRight).origin == CGPoint(x: -308, y: 8))
        #expect(OverlayPlacement.frame(size: size, visibleFrame: left, corner: .topRight, inset: 0).origin
                == CGPoint(x: -300, y: 1036))
    }

    // MARK: - OverlayPlacement.screenIndex

    @Test func screenIndexFollowsMouse() {
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
        #expect(OverlayPlacement.screenIndex(mouse: CGPoint(x: 700, y: 400), screenFrames: screens, mainIndex: 0) == 0)
        #expect(OverlayPlacement.screenIndex(mouse: CGPoint(x: -500, y: 1000), screenFrames: screens, mainIndex: 0) == 1)
        #expect(OverlayPlacement.screenIndex(mouse: CGPoint(x: 5000, y: 5000), screenFrames: screens, mainIndex: 0) == 0)
        #expect(OverlayPlacement.screenIndex(mouse: CGPoint(x: 5000, y: 5000), screenFrames: screens, mainIndex: 1) == 1)
        #expect(OverlayPlacement.screenIndex(mouse: .zero, screenFrames: [], mainIndex: 0) == 0)
        // Edges follow NSMouseInRect (unflipped): minX and maxY belong to the screen, maxX and minY do not.
        #expect(OverlayPlacement.screenIndex(mouse: CGPoint(x: 0, y: 400), screenFrames: screens, mainIndex: 1) == 0)
        #expect(OverlayPlacement.screenIndex(mouse: CGPoint(x: 700, y: 982), screenFrames: screens, mainIndex: 1) == 0)
        #expect(OverlayPlacement.screenIndex(mouse: CGPoint(x: -1, y: 1080), screenFrames: screens, mainIndex: 0) == 1)
    }
}
