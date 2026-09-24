import Foundation

public enum SensorID: String, CaseIterable, Sendable, Codable {
    case processes, coalitions, rootMemory, hostCPU, memory, soc, gpuClients, temperatures, smc, thermalState
    case networkFlows, interfaces, wifi, latency, diskIO, volumes, smart, battery, sleepAssertions, device
}

/// `[SensorID: …]` (e.g. `RawTick.health`) encodes as a JSON object keyed by rawValue, not a flat array.
extension SensorID: CodingKeyRepresentable {}

public enum SensorError: Error, Sendable, Codable, Equatable {
    /// Permanent for this launch (weak symbol missing, no hardware, struct size mismatch).
    case unavailable(String)
    case permissionDenied(String)
    /// errno + context.
    case posix(Int32, String)
    case transient(String)
    case timeout

    /// Maps the current `errno`: EPERM/EACCES → `.permissionDenied`, else `.posix`.
    public static func fromErrno(_ context: String) -> SensorError {
        fromErrno(errno, context)
    }

    /// Testable core of `fromErrno(_:)`.
    static func fromErrno(_ code: Int32, _ context: String) -> SensorError {
        switch code {
        case EPERM, EACCES: .permissionDenied("\(context): \(String(cString: strerror(code)))")
        default: .posix(code, context)
        }
    }
}

public enum SensorStatus: Sendable, Codable, Equatable {
    case ok, degraded(String), unavailable(String), disabled(String)

    public var reason: String? {
        switch self {
        case .ok: nil
        case .degraded(let r), .unavailable(let r), .disabled(let r): r
        }
    }
}

/// When a sensor is due. A zero interval means every tick.
public struct SensorCadence: Sendable, Equatable {
    public var interactive: Duration
    /// nil = never in background.
    public var background: Duration?
    /// Overlay-mode interval; nil = the background cadence, at least the background tick (R1).
    public var overlay: Duration?
    /// [] = always; else only when demand ∩ requires ≠ ∅.
    public var requires: SamplingDemand

    public init(interactive: Duration = .zero, background: Duration? = nil, overlay: Duration? = nil,
                requires: SamplingDemand = []) {
        self.interactive = interactive
        self.background = background
        self.overlay = overlay
        self.requires = requires
    }

    /// Interval in `mode`; nil = not sampled. Overlay without its own interval runs at `max(background, 5 s)`,
    /// so every-tick sensors stay at 5 s there; a nil `background` means never.
    public func interval(in mode: SamplingMode) -> Duration? {
        switch mode {
        case .interactive: interactive
        case .background: background
        case .paused: nil
        case .overlay: overlay ?? background.map { max($0, SamplingMode.background.interval!) }
        }
    }

    /// Every tick in interactive and background; background cadence (5 s) in overlay.
    public static let everyTick = SensorCadence(interactive: .zero, background: .zero)
    /// Every tick in every mode, overlay included: the CPU, GPU and memory totals the overlay shows.
    public static let totals = SensorCadence(interactive: .zero, background: .zero, overlay: .zero)
    /// Sampled once per launch; slots recognise it by equality (`cadence == .once`). The interval is a
    /// ~68-year sentinel, so arithmetic on it can't overflow a clock instant.
    public static let once = SensorCadence(interactive: .seconds(Int64(Int32.max)), background: .seconds(Int64(Int32.max)))

    public static func every(_ d: Duration, background: Duration? = nil, overlay: Duration? = nil,
                             requires: SamplingDemand = []) -> SensorCadence {
        SensorCadence(interactive: d, background: background, overlay: overlay, requires: requires)
    }
}

public struct SampleContext: Sendable {
    public var uptimeNs: UInt64, wallTime: Date, mode: SamplingMode, demand: SamplingDemand
    /// Overall level of the previous tick.
    public var alertLevel: AlertLevel

    public init(
        uptimeNs: UInt64 = 0,
        wallTime: Date = Date(timeIntervalSince1970: 0),
        mode: SamplingMode = .background,
        demand: SamplingDemand = [],
        alertLevel: AlertLevel = .calm
    ) {
        self.uptimeNs = uptimeNs
        self.wallTime = wallTime
        self.mode = mode
        self.demand = demand
        self.alertLevel = alertLevel
    }
}

public protocol Sensor<Reading>: AnyObject {
    associatedtype Reading: Sendable & Codable
    var id: SensorID { get }
    var cadence: SensorCadence { get }
    /// Open handles, check weak symbols (`tt_*_available()`). Lazy, on the sampler executor. Cheap:
    /// no sweeps (e.g. SMC reads only hard-coded keys; the full key sweep runs off-queue once and is cached).
    func prepare() throws(SensorError)
    /// Fast; never blocks > 250 ms. Async sources return their last completed result and kick off the next.
    /// Returns the reading and the uptime (ns) at which it was captured.
    func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: Reading, capturedNs: UInt64)
    func invalidate()
}
