import AppKit
import ClipboardCore
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Clipboard picker content (DESIGN §3.18): search field, optional Accessibility banner, list, key-hint footer.
/// It sets no key handlers for the commands in `ClipboardPickerKey`: the App's panel maps key events to
/// `ClipboardPickerModel.handle` before the search field sees them.
public struct ClipboardPickerView: View {
    public static let size = CGSize(width: 420, height: 460)

    private let model: ClipboardPickerModel

    public init(model: ClipboardPickerModel) {
        self.model = model
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: TTRadius.window, style: .continuous)
        VStack(spacing: 0) {
            ClipboardSearchField(model: model)
            if model.needsAccessibility {
                TTAlertBanner(
                    title: "Accessibility",
                    message: "Allow Warden in Accessibility to paste into the app in front. Until then items are only copied.",
                    level: .elevated,
                    actions: [BannerAction(id: "open", title: "Open System Settings") {
                        model.actions.openAccessibilitySettings()
                    }])
            }
            ClipboardList(model: model)
            ClipboardFooter()
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(shape.fill(TTColor.bgPopover))
        .overlay(shape.strokeBorder(TTColor.borderPopover, lineWidth: TTStroke.hairline))
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    /// "now" under a minute, then "5m", "3h", "2d". A clock set back (negative interval) reads "now".
    static func ageText(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

/// DESIGN §2.27 look at the picker's full width. `TTSearchField` cannot be focused from outside and clears itself
/// on Esc, which the panel routes to `ClipboardPickerModel.handle(.escape)` instead.
private struct ClipboardSearchField: View {
    @Bindable var model: ClipboardPickerModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: TTSpace.x6) {
            TTIcon(.search, size: 14, color: TTColor.textSecondary)
            TextField("", text: $model.query)
                .overlay(alignment: .leading) {
                    if model.query.isEmpty {
                        Text("Search clipboard history").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                            .lineLimit(1).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Search clipboard history")
                .textFieldStyle(.plain)
                .font(TTFont.body12)
                .foregroundStyle(TTColor.textPrimary)
                .tint(TTColor.accent)
                .focusEffectDisabled()
                .focused($focused)
        }
        .padding(.horizontal, TTSpace.x8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: TTRadius.r7, style: .continuous).fill(TTColor.fillField))
        .padding(.horizontal, TTSpace.x10)
        .padding(.top, TTSpace.x10)
        .padding(.bottom, TTSpace.x8)
        // The panel is key only after the view is on screen, and it is reused between opens.
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            focused = true
        }
    }
}

private struct ClipboardList: View {
    let model: ClipboardPickerModel

    var body: some View {
        let pinned = model.pinnedRows
        let recent = model.recentRows
        if pinned.isEmpty && recent.isEmpty {
            TTEmptyState(.empty(model.items.isEmpty ? "Nothing copied yet" : "No matches"))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !pinned.isEmpty { section("Pinned", pinned, offset: 0) }
                        if !recent.isEmpty { section(pinned.isEmpty && model.isSearching ? nil : "Recent", recent,
                                                     offset: pinned.count) }
                    }
                    .padding(.horizontal, TTSpace.x6)
                    .padding(.bottom, TTSpace.x6)
                }
                .scrollIndicators(.never)                    // an always-shown scroller track would narrow the rows
                .onChange(of: model.selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    @ViewBuilder private func section(_ title: String?, _ rows: [ClipItem], offset: Int) -> some View {
        if let title {
            Text(title)
                .font(TTFont.captionStrong).foregroundStyle(TTColor.textTertiary)
                .padding(.horizontal, TTSpace.x10).padding(.top, TTSpace.x6).padding(.bottom, TTSpace.x4)
        }
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
            ClipboardRow(model: model, item: item, quickIndex: offset + index < 9 ? offset + index + 1 : nil)
                .id(item.id)
        }
    }
}

/// 44-pt row: tile (thumbnail or kind icon), preview over "app · age", then pin and delete while hovered or
/// selected, and the ⌘1–⌘9 badge on the first nine rows.
private struct ClipboardRow: View {
    let model: ClipboardPickerModel
    let item: ClipItem
    let quickIndex: Int?
    @State private var hovering = false

    private var selected: Bool { model.selection == item.id }

    var body: some View {
        HStack(spacing: TTSpace.iconTextGapPopover) {
            tile
            VStack(alignment: .leading, spacing: 0) {
                Text(item.preview).font(TTFont.body13).foregroundStyle(TTColor.textPrimary)
                    .lineLimit(1).truncationMode(.tail)
                Text(subtitle).font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering || selected {
                TTIconButton(.pin, label: item.pinned ? "Unpin" : "Pin", variant: .rowAction,
                             tint: item.pinned ? TTColor.accent : nil) {
                    model.actions.setPinned(item, !item.pinned)
                }
                TTIconButton(.trash, label: "Delete", variant: .rowAction) { model.delete(item) }
            }
            if let quickIndex { TTBadge("⌘\(quickIndex)") }
        }
        .padding(.horizontal, TTSpace.x10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: TTRadius.r7, style: .continuous).fill(fill))
        .contentShape(Rectangle())
        .onTapGesture { model.actions.paste(item) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.preview), \(subtitle)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Paste") { model.actions.paste(item) }
    }

    private var fill: Color {
        if selected { return TTColor.rowSelected }
        return hovering ? TTColor.fillHover : .clear
    }

    private var subtitle: String {
        let age = ClipboardPickerView.ageText(since: item.lastUsedAt, now: model.now)
        guard let source = item.sourceName, !source.isEmpty else { return age }
        return "\(source) · \(age)"
    }

    private var icon: TTIconName {
        switch item.kind {
        case .text: .text
        case .files: .document
        case .image: .image
        }
    }

    @ViewBuilder private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: TTRadius.r5, style: .continuous)
        if item.kind == .image, let image = model.thumbnail(item) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 28, height: 28).clipShape(shape)
        } else {
            TTIcon(icon, size: 16, color: TTColor.textSecondary)
                .frame(width: 28, height: 28)
                .background(shape.fill(TTColor.fillTrack))
        }
    }
}

/// Key hints, 32 pt, top `separator`.
private struct ClipboardFooter: View {
    private static let hints: [(key: String, action: String)] = [
        ("↩", "Paste"), ("⌘1–9", "Quick paste"), ("⌘P", "Pin"), ("⌘⌫", "Delete"), ("Esc", "Close"),
    ]

    var body: some View {
        HStack(spacing: TTSpace.x12) {
            ForEach(Self.hints, id: \.key) { hint in
                HStack(spacing: TTSpace.x4) {
                    Text(hint.key).foregroundStyle(TTColor.textSecondary)
                    Text(hint.action).foregroundStyle(TTColor.textTertiary)
                }
            }
        }
        .font(TTFont.caption)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, TTSpace.x12)
        .frame(height: 32)
        .overlay(alignment: .top) { TTSeparator() }
    }
}
