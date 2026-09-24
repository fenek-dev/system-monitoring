import Dispatch
import MonitorModel

// W0b stub (ARCHITECTURE §5.6). W1 replaces this file.

public actor SamplingEngine {
    private let queue = DispatchSerialQueue(label: "dev.telltale.sampler", qos: .utility)

    public init(factory: SensorFactory, disabled: Set<SensorID> = [], alertConfig: AlertConfig = .init(),
                recordConfig: RecordConfig = .init(), canary: CrashCanary = .standard) {
        liveFrames = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { $0.finish() }
        records = AsyncStream { $0.finish() }
    }

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    /// bufferingNewest(1).
    public nonisolated let liveFrames: AsyncStream<SystemFrame>
    /// Unbounded, ~1 element/tick.
    public nonisolated let records: AsyncStream<RecordBatch>

    public func start() {}
    public func stop() async {}
    /// Cancels the stored sleeper (§4).
    public func setVisibility(_ v: UIVisibility) {}
    public func setPaused(_ paused: Bool) {}
    public func systemWillSleep() {}
    public func systemDidWake() {}
    public func sampleOnce() -> SystemFrame { SystemFrame() }
    /// telltale-probe --record/--frames.
    public func sampleOnceRaw() -> (tick: RawTick, frame: SystemFrame) { (RawTick(), SystemFrame()) }
}
