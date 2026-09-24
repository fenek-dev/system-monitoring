import MonitorModel
import SwiftUI

/// Popover rows (MenuBar@2x rows at (74, 87), 348 wide) and the sidebar nav (Main@2x at (0, 0), 220 wide).
@MainActor enum GalleryPopover {
    static var items: [TTGallery.Item] {
        [
            .init(id: "popover-rows", size: CGSize(width: 348, height: 301)) { AnyView(PopoverRows(stressed: false)) },
            .init(id: "popover-rows-alert", size: CGSize(width: 348, height: 301)) { AnyView(PopoverRows(stressed: true)) },
            .init(id: "popover-expanded", size: CGSize(width: 348, height: 272)) { AnyView(PopoverExpanded()) },
            .init(id: "sidebar", size: CGSize(width: 220, height: 460)) { AnyView(SidebarSample()) },
        ]
    }
}

private func app(_ name: String, cpu: Double? = nil, mem: UInt64? = nil, watts: Double? = nil) -> AppSample {
    AppSample(identity: AppIdentity(key: AppKey(kind: .app, id: name), displayName: name), cpuPercent: cpu, memory: mem,
              energyWatts: watts)
}

private let apps = [
    app("Xcode", cpu: 212.4, mem: 4_101_693_768, watts: 12.4),
    app("Final Cut Pro", cpu: 96.1, mem: 5_476_083_302, watts: 7.15),
    app("Safari", cpu: 18.7, mem: 2_061_584_302, watts: 0.94),
    app("WindowServer", cpu: 14.2, mem: 1_159_641_169, watts: 0.81),
]

private struct PopoverRows: View {
    let stressed: Bool
    @State var open = false

    var body: some View {
        VStack(spacing: 0) {
            TTPopoverRow(category: .cpu, subtitle: "12 cores · 4.1 GHz", value: stressed ? "66%" : "29%",
                         points: SampleSeries.wave(base: 0.29, amplitude: 0.04, seed: 1), compact: false,
                         expanded: $open, topApps: apps)
            TTPopoverRow(category: .gpu, subtitle: "1,180 MHz", value: stressed ? "45%" : "22%",
                         points: SampleSeries.wave(base: 0.12, amplitude: 0.04, seed: 2), compact: false,
                         expanded: $open, topApps: apps)
            TTPopoverRow(category: .memory, subtitle: "pressure normal", value: "15.2 GB",
                         points: SampleSeries.wave(base: 15.2, amplitude: 0.1, seed: 3), yDomain: 0...24, compact: false,
                         expanded: $open, topApps: apps, level: .calm)
            TTPopoverRow(category: .network, subtitle: "↑ 1.6 MB/s", value: "11.1 MB/s",
                         points: SampleSeries.wave(base: 9e6, amplitude: 4e6, seed: 4), compact: false,
                         expanded: $open, topApps: apps)
            TTPopoverRow(category: .thermals, subtitle: stressed ? "Fair · fans 3,900 rpm" : "Nominal · 2,140 rpm",
                         value: stressed ? "85°C" : "63°C",
                         points: SampleSeries.wave(base: stressed ? 84 : 62, amplitude: 0.8, seed: 5), compact: false,
                         expanded: $open, topApps: apps, level: stressed ? .elevated : .calm)
            TTPopoverDivider()
            TTPopoverRow(category: .power, subtitle: stressed ? "82% · 2 h 10 m left" : "82% · 5 h 40 m left",
                         value: stressed ? "37.9 W" : "15.1 W", points: [], compact: true, expanded: $open, topApps: apps)
            TTPopoverRow(category: .disk, subtitle: "R 142 · W 38.0 MB/s", value: "382 GB", points: [], compact: true,
                         expanded: $open, topApps: apps)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x28282C))
    }
}

private struct PopoverExpanded: View {
    @State var open = true
    @State var thermalsOpen = true
    var body: some View {
        VStack(spacing: 0) {
            TTPopoverRow(category: .cpu, subtitle: "12 cores · 4.1 GHz", value: "29%",
                         points: SampleSeries.wave(base: 0.29, amplitude: 0.04, seed: 1), compact: false,
                         expanded: $open, topApps: apps)
            TTPopoverRow(category: .thermals, subtitle: "Fair · fans 3,900 rpm", value: "85°C",
                         points: SampleSeries.wave(base: 84, amplitude: 0.8, seed: 5), compact: false,
                         expanded: $thermalsOpen, topApps: apps, level: .elevated)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x28282C))
    }
}

private struct SidebarSample: View {
    let values: [DashboardPage: String] = [
        .cpu: "29%", .gpu: "22%", .memory: "15.2 GB", .network: "11.1 MB/s", .thermals: "63°",
        .power: "15.1 W", .disk: "382 GB free",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Color.clear.frame(height: 52)
            ForEach(DashboardPage.Section.allCases, id: \.self) { section in
                TTSidebarSectionHeader(section)
                ForEach(DashboardPage.allCases.filter { $0.section == section }, id: \.self) { page in
                    TTSidebarItem(page: page, value: values[page], selected: page == .overview)
                }
            }
        }
        .padding(.horizontal, TTSpace.x10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TTColor.bgSidebar)
    }
}
