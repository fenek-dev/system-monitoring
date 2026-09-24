import MonitorModel
import SwiftUI

/// DESIGN §2.21 sidebar item: height 30, padding 10, radius 6, HStack gap 9 of the page icon 16 (category color;
/// Overview/Processes/History `textSecondary`), title `body13` `textPrimary` (flex), optional trailing value
/// `caption` `textSecondary` tabular ("—" when unavailable). Selected `fillSelectedSidebar`, hover `fillHover`;
/// the text color never changes. Items stack with gap 1.
public struct TTSidebarItem: View, Equatable {
    let page: DashboardPage
    let value: String?
    let selected: Bool
    @State private var hovering = false

    public init(page: DashboardPage, value: String?, selected: Bool) {
        self.page = page
        self.value = value
        self.selected = selected
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.page == b.page && a.value == b.value && a.selected == b.selected
    }

    /// Pages without a live value (Overview, Processes, History) show no trailing text.
    nonisolated static func hasValue(_ page: DashboardPage) -> Bool {
        switch page {
        case .overview, .processes, .history: false
        default: true
        }
    }

    public var body: some View {
        HStack(spacing: TTSpace.iconTextGapSidebar) {
            TTIcon(TTIconName.page(page), size: 16)
            Text(page.title)
                .font(TTFont.body13)
                .foregroundStyle(TTColor.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if Self.hasValue(page) {
                MetricValue(value, font: TTFont.caption)
                    .foregroundStyle(TTColor.textSecondary)
            }
        }
        .padding(.horizontal, TTSpace.x10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous)
                .fill(selected ? TTColor.fillSelectedSidebar : (hovering ? TTColor.fillHover : .clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: TTRadius.r6))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// DESIGN §3.0 sidebar section header ("Monitor", "System", "Activity"): `captionStrong` `textTertiary`,
/// padding 10 top, 10 horizontal, 4 bottom.
public struct TTSidebarSectionHeader: View {
    let title: String
    public init(_ title: String) { self.title = title }
    public init(_ section: DashboardPage.Section) {
        switch section {
        case .monitor: title = "Monitor"
        case .system: title = "System"
        case .activity: title = "Activity"
        }
    }

    public var body: some View {
        Text(title)
            .font(TTFont.captionStrong)
            .foregroundStyle(TTColor.textTertiary)
            .padding(.top, TTSpace.x10)
            .padding(.horizontal, TTSpace.x10)
            .padding(.bottom, TTSpace.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
