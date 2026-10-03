import AppKit
import MixerCore
import Observation

/// Per-app volume (MixerCore: Core Audio process taps). Runs from launch, so saved volumes apply whether or not the
/// side panel is shown. `panelOpen` is the popover header's toggle, persisted.
@MainActor
@Observable
final class MixerModel {
    let engine: MixerEngine
    @ObservationIgnored let wheel: ScrollWheelMonitor
    @ObservationIgnored private let monitor = AudioProcessMonitor()

    var panelOpen: Bool {
        didSet { UserDefaults.standard.set(panelOpen, forKey: Self.openKey) }
    }

    private static let openKey = "mixerPanelOpen"

    init() {
        let describer = AppDescriber()
        let engine = MixerEngine(
            store: VolumeStore(),
            permissions: AudioCapturePermission(),
            describe: describer.describe,
            factory: { try TapVolumeController(objectIDs: $0, gain: $1) })
        self.engine = engine
        wheel = ScrollWheelMonitor(engine: engine)
        panelOpen = UserDefaults.standard.bool(forKey: Self.openKey)
        monitor.onChange = { groups in
            MainActor.assumeIsolated { engine.update(groups: groups) }
        }
        monitor.onOutputDeviceChange = {
            MainActor.assumeIsolated { engine.outputDeviceChanged() }
        }
        monitor.start()
    }
}
