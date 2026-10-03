import AppKit
import MixerCore

/// Turns scroll-wheel movement over a row's slider into volume changes. Elsewhere the event
/// passes through, so the list still scrolls.
@MainActor
final class ScrollWheelMonitor {
    /// Row whose slider the pointer is over.
    var hoveredID: String? {
        didSet {
            if hoveredID != oldValue { accumulator.reset() }
        }
    }

    private var accumulator = StepAccumulator()

    private let engine: MixerEngine
    private var monitor: Any?

    init(engine: MixerEngine) {
        self.engine = engine
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let deltaY = event.scrollingDeltaY
            let precise = event.hasPreciseScrollingDeltas
            let used = MainActor.assumeIsolated { self?.handle(deltaY: deltaY, precise: precise) ?? false }
            return used ? nil : event
        }
    }

    /// True when the event was used.
    private func handle(deltaY: CGFloat, precise: Bool) -> Bool {
        guard let id = hoveredID, let row = engine.rows.first(where: { $0.id == id }) else { return false }
        // Trackpads report fine-grained points; a mouse wheel reports whole notches.
        let scale: Float = precise ? 0.002 : 0.02
        // Whole-percent steps, so the volume can land on exactly 100% and release the tap.
        let step = accumulator.add(Float(deltaY) * scale)
        if step != 0 {
            engine.setVolume(Gain.stepped(row.setting.volume, by: step), for: id)
        }
        return true
    }
}
