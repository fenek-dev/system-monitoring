import Foundation
import MonitorModel

/// Type-erased handle on one sensor of a `SensorSuite`, called directly (no `SensorSlot`: no cadence, cache,
/// backoff or canary). Readings are JSON-encoded lazily, only when printed or dumped.
struct ProbeSensor {
    let id: SensorID
    let cadence: SensorCadence
    let prepare: () -> SensorError?
    let sample: (SampleContext) -> Result<Sampled, SensorError>
    let invalidate: () -> Void

    struct Sampled {
        var capturedNs: UInt64
        var encode: (JSONEncoder) throws -> Data
    }

    init<R: Sendable & Codable>(_ s: any Sensor<R>) {
        id = s.id
        cadence = s.cadence
        prepare = {
            do throws(SensorError) {
                try s.prepare()
                return nil
            } catch {
                return error
            }
        }
        sample = { ctx in
            do throws(SensorError) {
                let (r, ns) = try s.sample(ctx)
                return .success(Sampled(capturedNs: ns, encode: { try $0.encode(r) }))
            } catch {
                return .failure(error)
            }
        }
        invalidate = { s.invalidate() }
    }

    /// Would the engine sample this sensor in `mode` with `demand`? (cadence + `requires`, as `SensorSlot` does.)
    func wanted(mode: SamplingMode, demand: SamplingDemand) -> Bool {
        if !cadence.requires.isEmpty, cadence.requires.isDisjoint(with: demand) { return false }
        return cadence.interval(in: mode) != nil
    }

    static func all(_ s: SensorSuite) -> [ProbeSensor] {
        [
            ProbeSensor(s.processes), ProbeSensor(s.coalitions), ProbeSensor(s.rootMemory), ProbeSensor(s.hostCPU),
            ProbeSensor(s.memory), ProbeSensor(s.soc), ProbeSensor(s.gpuClients), ProbeSensor(s.temperatures),
            ProbeSensor(s.smc), ProbeSensor(s.thermalState), ProbeSensor(s.networkFlows), ProbeSensor(s.interfaces),
            ProbeSensor(s.wifi), ProbeSensor(s.latency), ProbeSensor(s.diskIO), ProbeSensor(s.volumes),
            ProbeSensor(s.smart), ProbeSensor(s.battery), ProbeSensor(s.sleepAssertions), ProbeSensor(s.device),
        ]
    }
}

extension SensorError {
    var probeDescription: String {
        switch self {
        case .unavailable(let r): "unavailable: \(r)"
        case .permissionDenied(let r): "permission denied: \(r)"
        case .posix(let code, let ctx): "posix \(code) (\(String(cString: strerror(code)))): \(ctx)"
        case .transient(let r): "transient: \(r)"
        case .timeout: "timeout"
        }
    }
}

extension SensorCadence {
    var probeDescription: String {
        if self == .once { return "once" }
        func fmt(_ d: Duration) -> String {
            d == .zero ? "tick" : String(format: "%gs", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        var s = "i=\(fmt(interactive)) bg=\(background.map(fmt) ?? "never") ov=\(interval(in: .overlay).map(fmt) ?? "never")"
        if !requires.isEmpty { s += " requires=\(ProbeOptions.describe(requires))" }
        return s
    }
}

enum Clock {
    static func ns() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static func ms(_ ns: UInt64) -> String { String(format: "%.2f", Double(ns) / 1e6) }
}

struct Stats {
    var samples: [UInt64] = []
    mutating func add(_ v: UInt64) { samples.append(v) }
    /// Nearest rank.
    func percentile(_ p: Double) -> UInt64 {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((Double(sorted.count) * p).rounded(.up))
        return sorted[Swift.max(0, Swift.min(sorted.count, rank) - 1)]
    }
    var max: UInt64 { samples.max() ?? 0 }
    var total: UInt64 { samples.reduce(0, +) }
    var mean: UInt64 { samples.isEmpty ? 0 : total / UInt64(samples.count) }
}
