import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Launch-at-login control (`SMAppService.mainApp` in the app; a fake in renders/tests).
@MainActor
public struct LoginItemControl {
    public enum Status: Sendable, Equatable { case enabled, disabled, requiresApproval, unavailable(String) }

    public var status: @MainActor () -> Status
    /// Throws when registration fails; the view shows the error.
    public var setEnabled: @MainActor (Bool) throws -> Void
    /// `.requiresApproval`: opens System Settings › Login Items (`SMAppService.openSystemSettingsLoginItems()`).
    public var openSystemSettings: @MainActor () -> Void

    public init(status: @escaping @MainActor () -> Status, setEnabled: @escaping @MainActor (Bool) throws -> Void,
                openSystemSettings: @escaping @MainActor () -> Void = {}) {
        self.status = status
        self.setEnabled = setEnabled
        self.openSystemSettings = openSystemSettings
    }

    public static var preview: LoginItemControl { LoginItemControl(status: { .disabled }, setEnabled: { _ in }) }
}

/// About rows (DESIGN §3.14).
public struct AboutInfo: Sendable {
    public var version: String
    public var build: String
    /// e.g. "12.4 MB"; nil → "—". Loaded off the main actor when the view appears (file-system access can
    /// block, e.g. on a TCC prompt for a data dir under ~/Documents).
    public var historySize: @Sendable () async -> String?

    public init(version: String, build: String, historySize: @escaping @Sendable () async -> String?) {
        self.version = version
        self.build = build
        self.historySize = historySize
    }

    public static let preview = AboutInfo(version: "0.1.0", build: "1", historySize: { "12.4 MB" })
}

/// Settings window content (DESIGN §3.14): General, Units, Popover, Sensors (ADDED: re-enable), About.
public struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(LiveModel.self) private var live
    private let loginItem: LoginItemControl
    private let about: AboutInfo

    @State private var loginStatus: LoginItemControl.Status = .disabled
    @State private var loginError: String?
    @State private var sensorsReenabled = false
    @State private var historySize: String?

    public init(loginItem: LoginItemControl, about: AboutInfo) {
        self.loginItem = loginItem
        self.about = about
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                section("General") { launchAtLoginRow }
                section("Units") { unitRows }
                section("Popover") { popoverRows }
                if !disabledSensorRows.isEmpty { section("Sensors") { sensorRows } }
                section("About") { aboutRows }
            }
            .padding(20)
        }
        .frame(width: ShellStyle.settingsWidth, alignment: .top)
        .background(ShellStyle.bgWindow)
        .onAppear { loginStatus = loginItem.status() }
        .task { historySize = await about.historySize() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Settings").font(ShellStyle.pageTitle).foregroundStyle(ShellStyle.textPrimary)
            Spacer()
        }
        .padding(.leading, 80)
        .frame(height: ShellStyle.headerHeight)
        .background(ShellStyle.bgHeader)
        .overlay(alignment: .bottom) { ShellStyle.edgeHeader.frame(height: 1) }
    }

    // MARK: Sections

    private func section<C: View>(_ title: String, @ViewBuilder rows: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(ShellStyle.captionStrong).foregroundStyle(ShellStyle.textTertiary)
                .padding(.horizontal, 4).padding(.bottom, 6)
            VStack(spacing: 0) { rows() }
                .background(RoundedRectangle(cornerRadius: 10).fill(ShellStyle.bgCard))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ShellStyle.borderCard, lineWidth: 1))
        }
    }

    private func row<C: View>(height: CGFloat = 36, divider: Bool = true, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, 16)
            .frame(minHeight: height)
            .overlay(alignment: .top) {
                if divider { ShellStyle.separator.frame(height: 1).padding(.leading, 16) }
            }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(ShellStyle.body13).foregroundStyle(ShellStyle.textPrimary)
    }

    // General

    private var launchAtLoginRow: some View {
        row(divider: false) {
            VStack(alignment: .leading, spacing: 2) {
                label("Launch at login")
                if loginStatus == .requiresApproval {
                    Text("Requires approval in System Settings")
                        .font(ShellStyle.caption).foregroundStyle(ShellStyle.textTertiary)
                }
                if let loginError {
                    Text(loginError).font(ShellStyle.caption).foregroundStyle(ShellStyle.textTertiary).lineLimit(2)
                }
                if case .unavailable(let why) = loginStatus {
                    Text(why).font(ShellStyle.caption).foregroundStyle(ShellStyle.textTertiary).lineLimit(2)
                }
            }
            Spacer()
            if loginStatus == .requiresApproval {
                Button("Open Login Items") { loginItem.openSystemSettings() }
                    .controlSize(.small)
                    .help("Approve Telltale in System Settings › General › Login Items")
            }
            Toggle("", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { on in
                    do {
                        try loginItem.setEnabled(on)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    loginStatus = loginItem.status()
                }))
                .toggleStyle(.switch).controlSize(.small).tint(ShellStyle.accent).labelsHidden()
                .accessibilityLabel("Launch at login")
        }
        .padding(.vertical, 4)
    }

    // Units

    @ViewBuilder private var unitRows: some View {
        @Bindable var settings = settings
        row(divider: false) {
            label("Temperature")
            Spacer()
            TTSegmented(selection: $settings.units.temperature, options: [(.celsius, "°C"), (.fahrenheit, "°F")])
                .accessibilityLabel("Temperature unit")
        }
        row {
            label("Network rates")
            Spacer()
            TTSegmented(selection: $settings.units.networkRate, options: [(.bytes, "Bytes/s"), (.bits, "Bits/s")])
                .accessibilityLabel("Network rate unit")
        }
    }

    // Popover

    private var popoverRows: some View {
        List {
            ForEach(settings.popoverLayout.order, id: \.self) { c in
                HStack(spacing: 10) {
                    ShellIcon(kind: .dragHandle).icon(color: ShellStyle.textTertiary)
                    Circle().fill(TTColor.category(c)).frame(width: 8, height: 8).frame(width: 16, height: 16)
                    label(c.title)
                    Spacer()
                    Toggle("", isOn: Binding(get: { settings.isVisible(c) }, set: { settings.setVisible(c, $0) }))
                        .toggleStyle(.checkbox).tint(ShellStyle.accent).labelsHidden()
                        .disabled(!settings.canHide(c))
                        .accessibilityLabel("Show \(c.title) in the popover")
                }
                .frame(height: 32)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .onMove { settings.moveRows(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .environment(\.defaultMinListRowHeight, 32)
        .frame(height: CGFloat(settings.popoverLayout.order.count) * 32 + 8)
    }

    // Sensors (ADDED: ARCHITECTURE §5.13 "re-enable crashed/disabled sensors")

    /// Sensors the Sensors section lists: crash-disabled (`live.sensorHealth`, updated even while nothing is
    /// presenting) plus the kill-switch list in Settings. Sorted by id. Empty → no Sensors section.
    @MainActor public static func disabledSensors(live: LiveModel, settings: SettingsStore) -> [SensorID] {
        _ = live.healthVersion                                   // track health changes explicitly
        let crashed = live.sensorHealth.compactMap { id, status -> SensorID? in
            if case .disabled = status { return id }
            return nil
        }
        return Set(crashed).union(settings.disabledSensors).sorted { $0.rawValue < $1.rawValue }
    }

    private var disabledSensorRows: [SensorID] { Self.disabledSensors(live: live, settings: settings) }

    @ViewBuilder private var sensorRows: some View {
        let ids = disabledSensorRows
        row(divider: false) {
            VStack(alignment: .leading, spacing: 2) {
                label("Disabled sensors")
                Text(ids.map(\.rawValue).joined(separator: ", "))
                    .font(ShellStyle.caption).foregroundStyle(ShellStyle.textTertiary).lineLimit(2)
                if sensorsReenabled {
                    Text("Takes effect at next launch").font(ShellStyle.caption).foregroundStyle(ShellStyle.textTertiary)
                }
            }
            Spacer()
            Button("Re-enable sensors") {
                settings.reenableSensors()
                sensorsReenabled = true
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    // About

    @ViewBuilder private var aboutRows: some View {
        row(divider: false) {
            Text("Telltale \(about.version) (\(about.build))")
                .font(ShellStyle.caption).foregroundStyle(ShellStyle.textSecondary).monospacedDigit()
            Spacer()
        }
        row {
            Text("History: \(historySize ?? "—") on disk · kept 30 days")
                .font(ShellStyle.caption).foregroundStyle(ShellStyle.textSecondary).monospacedDigit()
            Spacer()
        }
    }
}

extension MonitorModel.Category {
    /// Popover/Settings row title.
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .thermals: "Thermals"
        case .power: "Power"
        case .disk: "Disk"
        }
    }
}
