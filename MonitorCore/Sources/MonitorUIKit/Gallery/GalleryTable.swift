import MonitorModel
import SwiftUI

/// Table gallery items: Processes list card (Processes@2x at (240, 74)), Overview top processes.
@MainActor enum GalleryTable {
    static var items: [TTGallery.Item] {
        [
            .init(id: "processes-list", size: CGSize(width: 1020, height: 330)) { AnyView(ProcessesList()) },
            .init(id: "search-field", size: CGSize(width: 240, height: 40)) { AnyView(SearchSample()) },
            // Main@2x "Top processes" at (240, 562): 1020×220 (template 2.2fr 1fr×5 28).
            .init(id: "top-processes", size: CGSize(width: 1020, height: 250)) { AnyView(TopProcesses()) },
            // Icon ruling: real icon only for an app bundle with its own icon; bundle-less / generic → letter tile.
            .init(id: "app-icons", size: CGSize(width: 150, height: 40)) {
                AnyView(
                    HStack(spacing: 10) {
                        TTAppTile(identity: AppIdentity(key: AppKey(kind: .app, id: "com.apple.calculator"), displayName: "Calculator",
                                                        bundlePath: "/System/Applications/Calculator.app"), name: "Calculator", size: 26)
                        TTAppTile(identity: AppIdentity(key: AppKey(kind: .process, id: "/bin/ls"), displayName: "ls",
                                                        bundlePath: "/bin/ls"), name: "ls", size: 26)
                        TTAppTile(identity: AppIdentity(key: AppKey(kind: .app, id: "dev.telltale.Telltale"), displayName: "Telltale",
                                                        bundlePath: "/nonexistent/Telltale.app"), name: "Telltale", size: 26)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TTColor.bgPopover)
                )
            },
            .init(id: "row-action", size: CGSize(width: 60, height: 34)) {
                AnyView(
                    TTRowActionsButton(target: .process(ProcessID(pid: 2210), name: "Final Cut Pro", path: nil, uid: 501),
                                       name: "Final Cut Pro")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(TTColor.bgCard)
                )
            },
        ]
    }
}

struct GalleryProcessRow: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String, kind: String, pid: Int32, user: String
    var cpu: Double, gpu: Double, mem: UInt64, net: Double, disk: Double, energy: Double
    var kids: [GalleryProcessRow] = []

    var identity: AppIdentity { AppIdentity(key: AppKey(kind: .app, id: name), displayName: name) }

    static let samples: [GalleryProcessRow] = [
        .init(name: "Xcode", kind: "App", pid: 1842, user: "arthur", cpu: 212.4, gpu: 0.4, mem: 4_101_693_768, net: 0,
              disk: 4_100_000, energy: 12.4),
        .init(name: "Final Cut Pro", kind: "App", pid: 2210, user: "arthur", cpu: 96.1, gpu: 9.2, mem: 5_476_083_302,
              net: 100_000, disk: 22_400_000, energy: 7.15),
        .init(name: "Safari", kind: "App", pid: 988, user: "arthur", cpu: 18.7, gpu: 2.3, mem: 2_061_584_302, net: 3_200_000,
              disk: 300_000, energy: 0.94),
        .init(name: "WindowServer", kind: "System", pid: 412, user: "_windowserver", cpu: 14.2, gpu: 5.1, mem: 1_159_641_169,
              net: 0, disk: 0, energy: 0.81),
        .init(name: "com.docker.backend", kind: "Background", pid: 2604, user: "arthur", cpu: 11.3, gpu: 0, mem: 1_567_663_063,
              net: 300_000, disk: 1_800_000, energy: 0.64),
    ]
}

private struct ProcessesList: View {
    @State var selection: String? = "Final Cut Pro"
    @State var sort: (column: String, descending: Bool) = ("cpu", true)
    @State var sortBy = "CPU"

    var columns: [TTTable<GalleryProcessRow>.Column] {
        typealias C = TTTable<GalleryProcessRow>.Column
        let units = UnitPreferences()
        return [
            C(id: "name", title: "Process", width: .fraction(2.2, min: 0)) {
                AnyView(TTNameCell(identity: $0.identity, name: $0.name, kind: $0.kind))
            },
            C(id: "pid", title: "PID", width: .fixed(64), alignment: .trailing) { AnyView(Text(String($0.pid))) },
            C(id: "user", title: "User", width: .fixed(110)) {
                AnyView(Text($0.user).foregroundStyle(TTColor.textSecondary))
            },
            C(id: "cpu", title: "% CPU", width: .fixed(70), alignment: .trailing, sortKey: { $0.cpu }) {
                AnyView(Text(TTFormat.cpuPercent($0.cpu, sign: false)))
            },
            C(id: "gpu", title: "% GPU", width: .fixed(64), alignment: .trailing, sortKey: { $0.gpu }) {
                AnyView(Text(TTFormat.cpuPercent($0.gpu, sign: false)))
            },
            C(id: "mem", title: "Memory", width: .fixed(84), alignment: .trailing, sortKey: { Double($0.mem) }) {
                AnyView(Text(TTFormat.bytes($0.mem)))
            },
            C(id: "net", title: "Network", width: .fixed(84), alignment: .trailing, sortKey: { $0.net }) {
                AnyView(MetricValue(TTFormat.rateCell($0.net, units: units), font: TTFont.body12))
            },
            C(id: "disk", title: "Disk", width: .fixed(84), alignment: .trailing, sortKey: { $0.disk }) {
                AnyView(MetricValue(TTFormat.diskRateCell($0.disk), font: TTFont.body12))
            },
            C(id: "energy", title: "Energy", width: .fixed(70), alignment: .trailing, sortKey: { $0.energy }) {
                AnyView(Text(TTFormat.appWatts($0.energy)))
            },
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            TTCard {
                HStack(spacing: TTSpace.x12) {
                    Text("Sort by").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                    TTSegmented(selection: $sortBy, options: ["CPU", "GPU", "Memory", "Network", "Disk", "Energy"].map { ($0, $0) })
                    Spacer(minLength: 0)
                    Text("10 of 612 shown").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                }
                TTTable(rows: GalleryProcessRow.samples, columns: columns, selection: $selection, sort: $sort,
                        style: .processes)
                    .frame(height: 28 + 4 + 5 * 35)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TTColor.bgWindow)
    }
}

private struct TopProcesses: View {
    @State var selection: String?
    @State var sort: (column: String, descending: Bool) = ("cpu", true)

    var body: some View {
        typealias C = TTTable<GalleryProcessRow>.Column
        let units = UnitPreferences()
        let columns = [
            C(id: "name", title: "Process", width: .fraction(2.2, min: 0)) {
                AnyView(TTNameCell(identity: $0.identity, name: $0.name))
            },
            C(id: "cpu", title: "CPU", width: .fraction(1, min: 0), alignment: .trailing, sortKey: { $0.cpu }) {
                AnyView(Text(TTFormat.cpuPercent($0.cpu)))
            },
            C(id: "gpu", title: "GPU", width: .fraction(1, min: 0), alignment: .trailing) { AnyView(Text(TTFormat.cpuPercent($0.gpu))) },
            C(id: "mem", title: "Memory", width: .fraction(1, min: 0), alignment: .trailing) { AnyView(Text(TTFormat.bytes($0.mem))) },
            C(id: "net", title: "Network", width: .fraction(1, min: 0), alignment: .trailing) {
                AnyView(MetricValue(TTFormat.rateCell($0.net, units: units), font: TTFont.body12))
            },
            C(id: "energy", title: "Energy impact", width: .fraction(1, min: 0), alignment: .trailing) {
                AnyView(Text(TTFormat.appWatts($0.energy)))
            },
            C(id: "actions", title: "", width: .fixed(28), alignment: .trailing) {
                AnyView(TTRowActionsButton(target: .process(ProcessID(pid: $0.pid), name: $0.name, path: nil, uid: 501),
                                           name: $0.name))
            },
        ]
        return TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Top processes") { TTLink("All processes") {} }
            TTTable(rows: GalleryProcessRow.samples, columns: columns, selection: $selection, sort: $sort)
                .frame(height: 26 + 4 + 5 * 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TTColor.bgWindow)
    }
}

private struct SearchSample: View {
    @State var text = ""
    var body: some View {
        TTSearchField(text: $text, prompt: "Search processes")
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TTColor.bgHeader)
    }
}
