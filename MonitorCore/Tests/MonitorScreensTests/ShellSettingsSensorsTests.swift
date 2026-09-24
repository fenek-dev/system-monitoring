import Foundation
import MonitorLive
import MonitorModel
@testable import MonitorScreens
import MonitorSnapshotTesting
import SwiftUI
import Testing

@Suite("Shell settings sensors") @MainActor
struct ShellSettingsSensorsTests {
    /// W7 T6 drill: after a crash, Settings opened on its own (popover and dashboard closed, LiveModel not
    /// presenting) must list the disabled sensor and offer Re-enable.
    private func crashedLive() -> LiveModel {
        let live = LiveModel()
        var f = SystemFrame()
        f.sensorHealth = [.smc: .disabled("Disabled after a crash")]
        live.apply(f)
        return live
    }

    @Test func crashDisabledSensorIsListedWhileNotPresenting() {
        let live = crashedLive()
        #expect(!live.isPresenting)
        let (settings, _) = ScreenFixture.settings()
        #expect(SettingsView.disabledSensors(live: live, settings: settings) == [.smc])
    }

    /// The rendered Settings window shows the Sensors section ("Disabled sensors · smc" + "Re-enable sensors").
    /// Golden `shell-settings-crashed-sensor` (visually checked).
    @Test(.enabled { await ScreenFixture.snapshotsAvailable })
    func crashDisabledSensorRendersWithReenable() {
        let (settings, _) = ScreenFixture.settings()
        let ctx = ShellContext(live: crashedLive(), settings: settings, isSnapshot: true)
        let size = CGSize(width: ScreenSize.settings.width, height: 720)
        assertSnapshot(SettingsView(loginItem: .preview, about: .preview)
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .background(ShellStyle.bgWindow)
                        .telltaleEnvironment(ctx),
                       size: size, named: "shell-settings-crashed-sensor")
    }

    @Test func noDisabledSensorsNoSectionKillSwitchListed() {
        let (settings, _) = ScreenFixture.settings()
        #expect(SettingsView.disabledSensors(live: LiveModel(), settings: settings).isEmpty)
        settings.setDisabled(.soc, true)
        #expect(SettingsView.disabledSensors(live: LiveModel(), settings: settings) == [.soc])
    }
}
