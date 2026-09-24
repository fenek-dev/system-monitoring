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

    /// App detail with a populated "Live connections" table (flows injected into the next frame).
    @Test func appDetailWithConnections() {
        let ctx = ScreenFixture.context(.calm, page: .processes)
        let provider = MockDataProvider(scenario: .calm)
        var frame = provider.frame(at: 61)
        if let safari = frame.apps.first(where: { $0.identity.displayName == "Safari" }),
           let pid = frame.processes.first(where: { $0.app == safari.identity.key })?.id {
            let hosts: [(String?, String, UInt16, TransportProtocol, Double, Double)] = [
                ("www.apple.com", "17.253.144.10", 443, .tcp, 1_840_000, 42_000),
                ("i.ytimg.com", "142.250.180.22", 443, .quic, 612_000, 9_800),
                (nil, "104.18.32.47", 443, .tcp, 96_000, 3_100),
                ("ocsp2.apple.com", "17.253.53.207", 80, .tcp, 0, 0),
                ("gateway.icloud.com", "17.248.176.12", 443, .tcp, 12_400, 18_600),
                (nil, "192.168.1.1", 53, .udp, 800, 400),
            ]
            frame.connections = hosts.enumerated().map { i, h in
                ConnectionSample(id: UInt64(i + 1), process: pid, app: safari.identity.key, proto: h.3,
                                 localPort: UInt16(50_000 + i), remoteAddress: h.1, remotePort: h.2, remoteHost: h.0,
                                 tcpState: "Established", rxBps: h.4, txBps: h.5)
            }
            ctx.live.apply(frame)
            ctx.navigation.selection = .app(safari.identity.key)
        }
        let view = DashboardRoot()
            .environment(\.processesDetailOnAppear, true)
            .frame(width: ScreenSize.dashboard.width, height: ScreenSize.dashboard.height)
            .telltaleEnvironment(ctx)
        assertSnapshot(view, size: ScreenSize.dashboard, named: "processes-connections-calm")
    }

    /// ICR-13: Docker Desktop expanded with an "Exited processes" row (italic, secondary, estimated, last child),
    /// selected → inspector shows no process detail.
    @Test func exitedProcessesRow() {
        let ctx = ScreenFixture.context(.calm, page: .processes)
        var frame = MockDataProvider(scenario: .calm).frame(at: 61)
        guard let docker = frame.apps.first(where: { $0.identity.displayName == "Docker Desktop" }) else {
            Issue.record("no Docker Desktop in the mock")
            return
        }
        let exited = ProcessSample(id: .exitedResidual(1), name: "Exited processes", user: "arthur",
                                   uid: 501, isCurrentUser: true, app: docker.identity.key, provenance: .coalition,
                                   cpuPercent: 6.4, diskReadBps: 180_000, energyWatts: 0.21, energyEstimated: true)
        frame.processes.append(exited)
        ctx.live.apply(frame)
        ctx.navigation.selection = .process(exited.id)
        ctx.navigation.processesMode = .apps
        let view = DashboardRoot()
            .environment(\.processesDetailOnAppear, false)
            .environment(\.processesExpandSelectionOnAppear, false)
            .environment(\.processesExpandOnAppear, [docker.identity.key])
            .frame(width: ScreenSize.dashboard.width, height: ScreenSize.dashboard.height)
            .telltaleEnvironment(ctx)
        assertSnapshot(view, size: ScreenSize.dashboard, named: "processes-exited-calm")
    }

    /// Design-match: the header search placeholder is `textSecondary` #A8A8B0, not near-white.
    @Test func searchFieldPlaceholder() {
        let view = VStack(alignment: .leading, spacing: 8) {
            TTSearchField(text: .constant(""), prompt: "Search processes")
            TTSearchField(text: .constant("xcode"), prompt: "Search processes")
        }
        .padding(12)
        .frame(width: 244, height: 88, alignment: .topLeading)
        .background(TTColor.bgHeader)
        .screenEnvironment(.calm, page: .processes)
        assertSnapshot(view, size: CGSize(width: 244, height: 88), named: "processes-search-field")
    }

    /// CP2: a long name truncates in the middle; the kind tag is never clipped.
    @Test func longNameKeepsKindTag() {
        let key = AppKey(kind: .process, id: "com.apple.audio.Core-Audio-Driver-Service.helper")
        let ps = [PT.proc(812, "com.apple.audio.Core-Audio-Driver-Service.helper", app: key, cpu: 1.2, user: "root",
                          uid: 0),
                  PT.proc(813, "com.apple.audio.Core-Audio-Driver-Service.helper", app: key, cpu: 0.4, user: "root",
                          uid: 0)]
        let out = ProcessTableModel.build(ProcessTableInput(processes: ps, apps: PT.group(ps)))
        let view = ProcessListTable(lines: out.lines, emptyMessage: "", showsDisclosure: true, selection: nil,
                                    sort: .cpu, descending: true, onSelect: { _ in }, onSort: { _ in },
                                    onToggle: { _ in }, onDoubleClick: { _ in })
            .padding(16)
            .frame(width: 986, height: 120)
            .background(TTColor.bgCard)
            .screenEnvironment(.calm, page: .processes)
        assertSnapshot(view, size: CGSize(width: 986, height: 120), named: "processes-row-longname")
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
