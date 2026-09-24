import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorUIKit
import SwiftUI
import Testing

/// Advisory perf probe (ARCHITECTURE §7; budget ≤ 16 ms, reported not enforced): the `restricted` scenario
/// (~920 rows) at 1-s ticks — `ProcessTableModel` apply per frame, and a full dashboard render.
@Suite("Processes perf (advisory)")
@MainActor
struct ProcessesPerfTests {
    @Test func restrictedApplyAndRender() {
        let provider = MockDataProvider(scenario: .restricted)
        let live = LiveModel.mock(.restricted)
        let table = ProcessTableModel()
        table.update(from: live, mode: .processes)
        var applyMs: [Double] = []
        for tick in 61...80 {
            live.apply(provider.frame(at: tick))
            let t0 = DispatchTime.now().uptimeNanoseconds
            table.update(from: live, mode: .processes)
            applyMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        #expect(table.lines.count > 300)                                  // mock `restricted`: ~370 pids
        let entry = ScreenCatalog.entry("processes")!
        var renderMs: [Double] = []
        for _ in 0..<3 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = SnapshotRenderer.render(entry.make(.restricted), size: entry.size, scale: 1)
            renderMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        let apply = applyMs.sorted()[applyMs.count / 2]
        let render = renderMs.sorted()[renderMs.count / 2]
        print(String(format: "PERF processes restricted rows=%d apply median %.2f ms (max %.2f) · render median %.1f ms",
                     table.lines.count, apply, applyMs.max() ?? 0, render))
    }
}
