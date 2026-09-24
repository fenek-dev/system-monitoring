import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// The popover's top-apps flyout (DESIGN §2.22 "Flyout"): popover chrome (`bgPopover`, 1-pt `borderPopover`,
/// radius 12, padding 6), 320 wide.
/// - Header (padding 8 top / 10 side / 6 bottom, gap 8): category icon 16, "Top CPU" `body12Strong` + " · 34% total"
///   `textSecondary`.
/// - Thermals: "by power" `caption` `textTertiary` under the header.
/// - Up to 10 lines of 26, radius 6, hover `fillHover`, padding 10 horizontal, gap 8: tile 16 · name `body12`
///   middle-truncated (flex) · share bar 48×4 (`fillTrack` track, category-color fill = share of Σ all apps) ·
///   value 64 wide right-aligned `body12` tabular `textSecondary`. Click → `appCommands.inspectApp`.
/// - No apps: "No app activity" `caption` `textTertiary`.
/// Re-renders each tick (reads `appsVersion` + the category snapshot); ranking is cached per apps version.
public struct FlyoutView: View {
    public static let width: CGFloat = 320

    let category: MonitorModel.Category
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units
    @State private var cache = FlyoutLinesCache()

    public init(category: MonitorModel.Category) {
        self.category = category
    }

    public var body: some View {
        let lines = cache.lines(live: live, category: category)
        let total = FlyoutModel.total(category, live: live, units: units)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header(total: total)
            if category == .thermals && !lines.isEmpty {
                Text("by power").font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
                    .padding(.horizontal, TTSpace.x10).frame(height: 16, alignment: .top)
            }
            if lines.isEmpty {
                Text("No app activity").font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
                    .padding(.horizontal, TTSpace.x10).frame(height: 26)
            }
            ForEach(lines, id: \.identity.key) { line in
                FlyoutLineView(line: line, category: category,
                               value: FlyoutModel.format(line.value, category, units: units))
            }
        }
        .padding(6)
        .frame(width: Self.width, alignment: .leading)
        .background(shape.fill(ShellStyle.bgPopover))
        .overlay(shape.strokeBorder(ShellStyle.borderPopover, lineWidth: 1))
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FlyoutModel.header(category, total: total))
    }

    private func header(total: String?) -> some View {
        HStack(spacing: TTSpace.x8) {
            TTIcon(TTIconName.category(category), size: 16)
            (Text(FlyoutModel.headerTitle(category)).font(TTFont.body12Strong).foregroundStyle(TTColor.textPrimary)
             + Text(FlyoutModel.headerDetail(category, total: total).map { " · \($0)" } ?? "")
                .font(TTFont.body12).foregroundStyle(TTColor.textSecondary))
                .lineLimit(1)
                .monospacedDigit()
        }
        .padding(EdgeInsets(top: 8, leading: TTSpace.x10, bottom: 6, trailing: TTSpace.x10))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One app line; hover fill, click → the app in the dashboard inspector.
struct FlyoutLineView: View {
    let line: FlyoutLine
    let category: MonitorModel.Category
    let value: String
    @Environment(\.appCommands) private var commands
    @State private var hovering = false

    static let barWidth: CGFloat = 48

    var body: some View {
        HStack(spacing: TTSpace.x8) {
            TTAppTile(identity: line.identity, name: line.name, size: 16)
            Text(line.name).font(TTFont.body12).foregroundStyle(TTColor.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            shareBar
            Text(value).font(TTFont.body12).monospacedDigit().foregroundStyle(TTColor.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, TTSpace.x10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous)
            .fill(hovering ? TTColor.fillHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { commands.inspectApp(line.identity.key) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.name)
        .accessibilityValue("\(value), \(Int((line.share * 100).rounded()))% of total")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { commands.inspectApp(line.identity.key) }
    }

    private var shareBar: some View {
        let share = min(max(line.share, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule().fill(TTColor.fillTrack)
            Capsule().fill(TTColor.category(category))
                .frame(width: share > 0 ? max(2, Self.barWidth * share) : 0)
        }
        .frame(width: Self.barWidth, height: 4)
    }
}
