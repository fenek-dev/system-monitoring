import Foundation
import MonitorLive
import MonitorMocks
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import MonitorUIKit
import SwiftUI
import Testing

@Suite("Processes snapshots")
@MainActor
struct ProcessesSnapshotTests {
    @Test func calm() { assertScreen("processes", scenario: .calm) }
    @Test func restricted() { assertScreen("processes", scenario: .restricted) }
    @Test func sensorsUnavailable() { assertScreen("processes", scenario: .sensorsUnavailable) }
    @Test func collecting() { assertScreen("processes", scenario: .collecting) }

    /// The artboard's state: Processes mode, Final Cut Pro selected, inspector collapsed.
    @Test func selectedLikeArtboard() {
        assertSnapshot(Self.dashboard(.calm, mode: .processes, select: "Final Cut Pro", detail: false),
                       size: ScreenSize.dashboard, named: "processes-selected-calm")
    }

    /// App detail expanded (Apps mode, Docker Desktop expanded + selected).
    @Test func appDetail() {
        assertSnapshot(Self.dashboard(.calm, mode: .apps, select: "Docker Desktop", detail: true, expand: true),
                       size: ScreenSize.dashboard, named: "processes-detail-calm")
    }

    /// Coalition group expanded: synthetic row, "+N restricted", "—" memory with the root tooltip.
    @Test func restrictedExpanded() {
        let live = ScreenFixture.live(.restricted)
        let coalition = live.apps.first { a in live.processes(of: a.identity.key).contains { $0.id.isSynthetic } }
        assertSnapshot(Self.dashboard(.restricted, mode: .apps, select: coalition?.identity.displayName, detail: true,
                                      expand: true),
                       size: ScreenSize.dashboard, named: "processes-restricted-expanded")
    }

    static func dashboard(_ scenario: MockScenario, mode: NavigationModel.ProcessesMode, select name: String?,
                          detail: Bool, expand: Bool = false) -> some View {
        let ctx = ScreenFixture.context(scenario, page: .processes)
        ctx.navigation.processesMode = mode
        if let name, let app = ctx.live.apps.first(where: { $0.identity.displayName == name }) {
            if mode == .apps {
                ctx.navigation.selection = .app(app.identity.key)
            } else if let p = ctx.live.processes(of: app.identity.key).first(where: { !$0.id.isSynthetic }) {
                ctx.navigation.selection = .process(p.id)
            }
        }
        return DashboardRoot()
            .environment(\.processesDetailOnAppear, detail)
            .environment(\.processesExpandSelectionOnAppear, expand)
            .frame(width: ScreenSize.dashboard.width, height: ScreenSize.dashboard.height)
            .telltaleEnvironment(ctx)
    }
}
