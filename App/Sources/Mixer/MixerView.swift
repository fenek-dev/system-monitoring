import MixerCore
import MonitorUIKit
import SwiftUI

/// Volume-mixer side panel content: one row per app playing audio (or with a saved volume), solo and permission
/// banners, a footer to show hidden apps. `PopoverContainer` adds the chrome.
struct MixerView: View {
    static let width: CGFloat = 340
    private static let maxListHeight: CGFloat = 432

    let engine: MixerEngine
    let wheel: ScrollWheelMonitor

    /// Row order captured when the pointer entered the list.
    @State private var frozenOrder: [String]?
    @State private var selectedID: String?
    @State private var showHidden = false
    @FocusState private var listFocused: Bool

    private var hiddenCount: Int { engine.rows.filter(\.hidden).count }

    private var rows: [MixerEngine.Row] {
        RowOrdering.apply(frozen: frozenOrder, to: engine.rows.filter { showHidden || !$0.hidden })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Volume Mixer")
                .font(TTFont.sectionTitle)
                .foregroundStyle(TTColor.textPrimary)
                .padding(EdgeInsets(top: 10, leading: 10, bottom: 8, trailing: 10))

            if engine.permission == .denied {
                permissionBanner
            }
            if let soloID = engine.soloID {
                soloBanner(soloID)
            }

            if rows.isEmpty {
                Text("No apps playing audio")
                    .font(TTFont.caption)
                    .foregroundStyle(TTColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                list
            }

            if hiddenCount > 0 {
                TTSeparator().padding(.vertical, 4).padding(.horizontal, 10)
                footer
            }
        }
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.2), value: rows.map(\.id))
        .onAppear(perform: refresh)
        // Focus needs a key window: the panel becomes key only once the pointer enters it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    AppRowView(row: row, engine: engine, wheel: wheel, isSelected: selectedID == row.id)
                        .onHover { inside in
                            if inside { selectedID = row.id }
                        }
                }
            }
        }
        // The panel sizes to its content and a scroll view has no height of its own.
        .frame(height: min(CGFloat(rows.count) * AppRowView.height, Self.maxListHeight))
        .scrollBounceBehavior(.basedOnSize)
        .disabled(engine.permission == .denied)
        .onHover { inside in
            frozenOrder = inside ? rows.map(\.id) : nil
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        .accessibilityLabel("Applications")
    }

    private func refresh() {
        engine.refreshPermission()
        listFocused = true
    }

    /// Up/down select a row; left/right change it by 5% (1% with shift); m mutes, s solos,
    /// 0 silences, 1 resets to 100%.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let ids = rows.map(\.id)
        // Leave command, control and option combinations to the system.
        guard !ids.isEmpty, engine.permission != .denied,
              press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) }

        switch press.key {
        case .downArrow:
            selectedID = ids[min((index ?? -1) + 1, ids.count - 1)]
            return .handled
        case .upArrow:
            selectedID = ids[max((index ?? 1) - 1, 0)]
            return .handled
        default:
            break
        }

        guard let index else { return .ignored }
        let row = rows[index]
        let step: Float = press.modifiers.contains(.shift) ? 0.01 : 0.05
        switch press.key {
        case .leftArrow:
            engine.setVolume(Gain.stepped(row.setting.volume, by: -step), for: row.id)
        case .rightArrow:
            engine.setVolume(Gain.stepped(row.setting.volume, by: step), for: row.id)
        default:
            switch press.characters {
            case "m": engine.setMuted(!row.setting.muted, for: row.id)
            case "s": engine.solo(engine.soloID == row.id ? nil : row.id)
            case "0": engine.setVolume(0, for: row.id)
            case "1": engine.reset(row.id)
            default: return .ignored
            }
        }
        return .handled
    }

    private func soloBanner(_ soloID: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones")
            Text("Only \(engine.rows.first { $0.id == soloID }?.name ?? "one app") is audible")
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("End Solo") { engine.solo(nil) }
                .controlSize(.small)
        }
        .font(TTFont.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(TTColor.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio recording permission is off, so app volumes cannot be changed.")
                .font(TTFont.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(showHidden ? "Hide \(hiddenCount) hidden" : "Show \(hiddenCount) hidden") {
                showHidden.toggle()
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .font(TTFont.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
