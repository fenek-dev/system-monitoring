import Foundation
import MonitorEngine
import MonitorLive
import MonitorModel
import MonitorSensors
import MonitorStore
import os

/// Live runtime (ARCHITECTURE §3, §4, §5.11): `SamplingEngine` over `SensorFactory.live` → frames into `LiveModel`
/// (MainActor), record batches into `HistoryStore` (off the MainActor). The store runs its own maintenance timer
/// (open + every 5 min, ruling); `shutdown()` stops the engine, drains the records and flushes the store.
///
/// Engine calls go through one ordered command queue: separate `Task { await engine.… }` per call could reorder
/// (e.g. pause/resume or visibility changes arriving out of order).
@MainActor final class LivePipeline: RuntimePipeline {
    let live: LiveModel
    let history: any HistoryProvider
    /// false when the file store could not be opened: history runs in memory for this launch (§6).
    let historyPersistent: Bool

    private let engine: SamplingEngine
    private let store: HistoryStore?
    private let commandStream: AsyncStream<Command>
    private let commands: AsyncStream<Command>.Continuation
    private var commandTask: Task<Void, Never>?
    private var frameTask: Task<Void, Never>?
    private var recordTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var state = State.idle
    /// Frames already in flight when sampling pauses must not flip the model back to live.
    private(set) var paused = false

    private enum State { case idle, running, shutDown }
    enum Command: Sendable { case start, visibility(UIVisibility), paused(Bool), willSleep, didWake }

    nonisolated static let log = Logger(subsystem: "dev.telltale", category: "Runtime")
    static let databaseName = "history.sqlite"

    convenience init(dataDirectory: URL, disabledSensors: Set<SensorID>, crashSensor: SensorID?,
                     canarySuite: String? = nil) {
        let (store, persistent) = Self.openStore(in: dataDirectory)
        let canary = TelltaleRuntime.canary(suite: canarySuite)
        let engine = SamplingEngine(factory: SensorFactory.live.crashing(crashSensor), disabled: disabledSensors,
                                    canary: canary)
        self.init(engine: engine, store: store, persistent: persistent)
    }

    /// Test seam: any engine (fixture sensors, short intervals) and store (in-memory).
    init(engine: SamplingEngine, store: HistoryStore?, persistent: Bool = true, live: LiveModel = LiveModel()) {
        self.engine = engine
        self.store = store
        self.historyPersistent = persistent && store != nil
        self.history = store ?? EmptyHistoryProvider()
        self.live = live
        (commandStream, commands) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .unbounded)
    }

    /// `dataDirectory/history.sqlite`; on failure an in-memory store (logged as a fault), else no store at all.
    static func openStore(in dataDirectory: URL) -> (HistoryStore?, persistent: Bool) {
        let url = dataDirectory.appendingPathComponent(databaseName)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            return (try HistoryStore(location: .file(url)), true)
        } catch {
            log.fault("history store at \(url.path, privacy: .public) failed to open: \(error.localizedDescription, privacy: .public); using memory")
        }
        do {
            return (try HistoryStore(location: .inMemory), false)
        } catch {
            log.fault("in-memory history store failed: \(error.localizedDescription, privacy: .public)")
            return (nil, false)
        }
    }

    // MARK: RuntimePipeline

    func start() {
        guard state == .idle else { return }
        state = .running
        let engine = self.engine
        commandTask = Task { await Self.runCommands(commandStream, engine) }
        recordTask = Task { await Self.pumpRecords(engine.records, into: store) }
        frameTask = Task { [weak self] in
            for await frame in engine.liveFrames {
                guard let self else { return }
                if !self.paused { self.live.apply(frame) }
            }
        }
        commands.yield(.start)
    }

    func setVisibility(_ v: UIVisibility) {
        guard state != .shutDown else { return }
        commands.yield(.visibility(v))
    }

    func setPaused(_ p: Bool) {
        guard state != .shutDown, p != paused else { return }
        paused = p
        if live.alert.paused != p { live.setPaused(p, at: Date()) }
        commands.yield(.paused(p))
    }

    func systemWillSleep() {
        guard state != .shutDown else { return }
        commands.yield(.willSleep)
    }

    func systemDidWake() {
        guard state != .shutDown else { return }
        commands.yield(.didWake)
    }

    /// Stops the engine (its closing episode events still reach the store), drains every record batch into the
    /// store, then `HistoryStore.shutdown()` (cancels and awaits maintenance, final flush). All of it runs off the
    /// MainActor, so the caller's 3 s MainActor timeout (TerminationController) can fire meanwhile.
    /// Repeated calls (e.g. ⌘Q while a SIGTERM shutdown runs) await the same shutdown.
    func shutdown() async {
        if let shutdownTask { return await shutdownTask.value }
        let started = state == .running
        state = .shutDown
        commands.finish()
        let (engine, store, commandTask) = (self.engine, self.store, self.commandTask)
        let recordTask = started ? self.recordTask : nil
        let task = Task {
            let t0 = ContinuousClock.now
            await Self.stopAndFlush(engine: engine, store: store, commandTask: commandTask, recordTask: recordTask)
            Self.log.notice("runtime shutdown in \(Int((ContinuousClock.now - t0) / .milliseconds(1))) ms")
        }
        shutdownTask = task
        await task.value
        frameTask?.cancel()
    }

    // MARK: Off-MainActor work (nonisolated async runs on the global executor)

    nonisolated private static func runCommands(_ stream: AsyncStream<Command>, _ engine: SamplingEngine) async {
        for await c in stream {
            switch c {
            case .start: await engine.start()
            case .visibility(let v): await engine.setVisibility(v)
            case .paused(let p): await engine.setPaused(p)
            case .willSleep: await engine.systemWillSleep()
            case .didWake: await engine.systemDidWake()
            }
        }
    }

    nonisolated private static func pumpRecords(_ records: AsyncStream<RecordBatch>, into store: HistoryStore?) async {
        for await batch in records { await store?.append(batch) }
    }

    nonisolated private static func stopAndFlush(engine: SamplingEngine, store: HistoryStore?,
                                                 commandTask: Task<Void, Never>?, recordTask: Task<Void, Never>?) async {
        await commandTask?.value                // queued commands (e.g. a last pause) reach the engine first
        await engine.stop()                     // finishes both streams after the closing batch
        await recordTask?.value                 // every batch appended
        do {
            try await store?.shutdown()
        } catch {
            log.error("history flush on shutdown failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
