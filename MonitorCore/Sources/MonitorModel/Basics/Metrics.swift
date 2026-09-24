import Foundation

public enum HistoryMetric: String, CaseIterable, Sendable, Codable {
    case cpuUsage, cpuUser, cpuSystem, cpuPCluster, cpuECluster, loadAvg1
    case gpuUsage, gpuFrequency
    case memUsed, memApp, memWired, memCompressed, memPressure, swapUsed
    case netRx, netTx, netLatency
    case diskRead, diskWrite, diskReadIOPS, diskWriteIOPS
    case socTemp, cpuPTemp, cpuETemp, gpuTemp, ssdTemp, batteryTemp, fan1RPM, fan2RPM
    case packageWatts, cpuWatts, gpuWatts, aneWatts, dramWatts, systemWatts, batteryPercent
    case thermalPressure

    /// Sensors that can produce this metric (any one suffices); used by `unavailableReason`.
    public var sources: [SensorID] {
        switch self {
        case .cpuUsage, .cpuUser, .cpuSystem, .cpuPCluster, .cpuECluster, .loadAvg1: [.hostCPU]
        case .gpuUsage: [.soc, .gpuClients]
        case .gpuFrequency: [.soc]
        case .memUsed, .memApp, .memWired, .memCompressed, .memPressure, .swapUsed: [.memory]
        case .netRx, .netTx: [.interfaces]
        case .netLatency: [.latency]
        case .diskRead, .diskWrite, .diskReadIOPS, .diskWriteIOPS: [.diskIO]
        case .socTemp, .cpuPTemp, .cpuETemp, .gpuTemp, .ssdTemp: [.smc]
        case .batteryTemp: [.battery, .smc]
        case .fan1RPM, .fan2RPM: [.smc]
        case .packageWatts, .cpuWatts, .gpuWatts, .aneWatts, .dramWatts: [.soc]
        case .systemWatts: [.smc]
        case .batteryPercent: [.battery]
        case .thermalPressure: [.thermalState]
        }
    }
}

public enum AppMetric: String, CaseIterable, Sendable, Codable {
    case cpu, gpu, memory, netRx, netTx, diskRead, diskWrite, energy

    /// Sensors that can produce this metric (any one suffices); used by `unavailableReason`.
    public var sources: [SensorID] {
        switch self {
        case .cpu: [.processes, .coalitions]
        case .gpu: [.gpuClients]
        case .memory: [.processes, .rootMemory]
        case .netRx, .netTx: [.networkFlows]
        case .diskRead, .diskWrite: [.processes, .coalitions]
        case .energy: [.processes, .coalitions, .soc]
        }
    }
}

public protocol MetricKey: CaseIterable, Hashable, Sendable, Codable, RawRepresentable where RawValue == String {
    /// Case → storage slot, computed once. Generic types can't hold static stored properties, so each
    /// concrete enum provides it: `static let ordinals = Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })`.
    static var ordinals: [Self: Int] { get }
    static var count: Int { get }
}

extension HistoryMetric: MetricKey {
    public static let ordinals: [HistoryMetric: Int] =
        Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
    public static let count = allCases.count
}

extension AppMetric: MetricKey {
    public static let ordinals: [AppMetric: Int] =
        Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
    public static let count = allCases.count
}

/// Fixed-size, allocation-free row (ContiguousArray<Double>, NaN = missing). Subscript uses Key.ordinals (no allCases scan).
/// Codable **by rawValue** as a keyed container {"cpuUsage": 0.42, …}; NaN omitted; unknown keys ignored,
/// so fixtures survive enum reordering and additions. Hashable/Equatable treat NaN slots as equal.
public struct MetricVector<Key: MetricKey>: Sendable, Codable, Hashable {
    /// One slot per case, indexed by `Key.ordinals`; NaN = missing (always the canonical `.nan`).
    private var storage: ContiguousArray<Double>

    public init() {
        storage = ContiguousArray(repeating: .nan, count: Key.count)
    }

    /// nil = missing. Assigning nil or any NaN clears the slot.
    public subscript(_ key: Key) -> Double? {
        get {
            let v = storage[Self.slot(key)]
            return v.isNaN ? nil : v
        }
        set {
            storage[Self.slot(key)] = newValue.flatMap { $0.isNaN ? nil : $0 } ?? .nan
        }
    }

    @inline(__always)
    private static func slot(_ key: Key) -> Int {
        guard let i = Key.ordinals[key] else { preconditionFailure("\(Key.self).ordinals is missing \(key)") }
        return i
    }

    // MARK: Equatable / Hashable (NaN slots equal each other)
    // Value compare, so ±0 are equal (accepted deviation from §5.2's "bit-pattern compare" wording).

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage.elementsEqual(rhs.storage) { a, b in (a.isNaN && b.isNaN) || a == b }
    }

    public func hash(into hasher: inout Hasher) {
        for v in storage {
            if v.isNaN { hasher.combine(UInt64.max) } else { hasher.combine(v) }
        }
    }

    // MARK: Codable (keyed by rawValue)

    private struct RawKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: RawKey.self)
        for codingKey in container.allKeys {
            guard let key = Key(rawValue: codingKey.stringValue) else { continue }   // unknown key: ignored
            self[key] = try container.decodeIfPresent(Double.self, forKey: codingKey)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RawKey.self)
        for key in Key.allCases {
            if let v = self[key] {
                try container.encode(v, forKey: RawKey(stringValue: key.rawValue))
            }
        }
    }
}

public typealias SystemMetrics = MetricVector<HistoryMetric>
public typealias AppMetrics = MetricVector<AppMetric>

public struct SeriesPoint: Sendable, Codable, Equatable {
    public var time: Date
    /// nil = gap.
    public var value: Double?

    public init(time: Date = Date(timeIntervalSince1970: 0), value: Double? = nil) {
        self.time = time
        self.value = value
    }
}
