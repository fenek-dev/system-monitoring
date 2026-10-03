import MonitorModel
import SwiftUI

/// Popover rows (MenuBar@2x popover content at (75, 87), 346 wide: 360 border-box − 1 border − 6 padding per side)
/// and the sidebar nav (Main@2x at (0, 0), 220 wide).
@MainActor enum GalleryPopover {
    static var items: [TTGallery.Item] {
        [
            .init(id: "popover-rows", size: CGSize(width: 346, height: 301)) { AnyView(PopoverRows(stressed: false)) },
            .init(id: "popover-rows-alert", size: CGSize(width: 346, height: 301)) { AnyView(PopoverRows(stressed: true)) },
            .init(id: "sidebar", size: CGSize(width: 220, height: 491)) { AnyView(SidebarSample()) },
        ]
    }
}

private struct PopoverRows: View {
    let stressed: Bool

    var body: some View {
        VStack(spacing: 0) {
            TTPopoverRow(category: .cpu, subtitle: "12 cores · 4.1 GHz", value: stressed ? "66%" : "29%",
                         points: SampleSeries.wave(base: 0.29, amplitude: 0.04, seed: 1), compact: false)
            TTPopoverRow(category: .gpu, subtitle: "1,180 MHz", value: stressed ? "45%" : "22%",
                         points: SampleSeries.wave(base: 0.12, amplitude: 0.04, seed: 2), compact: false)
            TTPopoverRow(category: .memory, subtitle: "pressure normal", value: "15.2 GB",
                         points: SampleSeries.wave(base: 15.2, amplitude: 0.1, seed: 3), yDomain: 0...24, compact: false,
                         level: .calm)
            TTPopoverRow(category: .network, subtitle: "↑ 1.6 MB/s", value: "11.1 MB/s",
                         points: SampleSeries.wave(base: 9e6, amplitude: 4e6, seed: 4), compact: false)
            TTPopoverRow(category: .thermals, subtitle: stressed ? "Fair · fans 3,900 rpm" : "Nominal · 2,140 rpm",
                         value: stressed ? "85°C" : "63°C",
                         points: SampleSeries.wave(base: stressed ? 84 : 62, amplitude: 0.8, seed: 5), compact: false,
                         level: stressed ? .elevated : .calm)
            TTPopoverDivider()
            TTPopoverRow(category: .power, subtitle: stressed ? "82% · 2 h 10 m left" : "82% · 5 h 40 m left",
                         value: stressed ? "37.9 W" : "15.1 W", points: [], compact: true)
            TTPopoverRow(category: .disk, subtitle: "R 142 · W 38.0 MB/s", value: "382 GB", points: [], compact: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: 0x28282C))
    }
}

private struct SidebarSample: View {
    let values: [DashboardPage: String] = [
        .cpu: "29%", .gpu: "22%", .memory: "15.2 GB", .network: "11.1 MB/s", .thermals: "63°",
        .power: "15.1 W", .disk: "382 GB free", .storage: "382 GB free",
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
