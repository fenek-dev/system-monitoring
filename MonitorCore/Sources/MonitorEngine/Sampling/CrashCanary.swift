import Foundation
import MonitorModel
import os

/// Crash canary (ARCHITECTURE §6): a marker is written before a sensor's first `prepare()`/`sample()` of a launch
/// and cleared at its first real reading (`.fresh`), or when it is ruled unavailable / invalidated — warming-up
/// errors keep it set, so off-queue setup is covered. A marker still present at the next launch means the sensor crashed the app;
/// that sensor is then disabled ("Disabled after a crash") until `reenableAll()` (Settings "Re-enable sensors").
public struct CrashCanary: Sendable {
    enum Storage: Sendable {
        case none
        case defaults(suite: String?)
        case memory(MemoryStore)
    }

    /// In-process marker store (tests).
    final class MemoryStore: Sendable {
        private let markers = OSAllocatedUnfairLock<Set<SensorID>>(initialState: [])
        func contains(_ id: SensorID) -> Bool { markers.withLock { $0.contains(id) } }
        func insert(_ id: SensorID) { _ = markers.withLock { $0.insert(id) } }
        func remove(_ id: SensorID) { _ = markers.withLock { $0.remove(id) } }
        func removeAll() { markers.withLock { $0.removeAll() } }
    }

    static let keyPrefix = "dev.telltale.crashCanary."
    static let disabledReason = "Disabled after a crash"

    let storage: Storage

    public static let standard = CrashCanary(storage: .defaults(suite: nil))
    public static let none = CrashCanary(storage: .none)

    /// Markers in a separate `UserDefaults` suite (e.g. per test or per data dir).
    public static func defaults(suite: String) -> CrashCanary { CrashCanary(storage: .defaults(suite: suite)) }
    static func inMemory() -> CrashCanary { CrashCanary(storage: .memory(MemoryStore())) }

    /// Marker present (checked once per slot at creation = at launch).
    public func isTripped(_ id: SensorID) -> Bool {
        switch storage {
        case .none: false
        case .defaults(let suite): Self.defaults(suite)?.bool(forKey: Self.keyPrefix + id.rawValue) ?? false
        case .memory(let m): m.contains(id)
        }
    }

    /// The marker must reach cfprefsd before the guarded call can crash the process: `synchronize()` pushes the
    /// write out of process synchronously (verified by `CrashCanaryPersistenceTests` via `/usr/bin/defaults`).
    func arm(_ id: SensorID) {
        switch storage {
        case .none: break
        case .defaults(let suite):
            guard let d = Self.defaults(suite) else { return }
            d.set(true, forKey: Self.keyPrefix + id.rawValue)
            d.synchronize()
        case .memory(let m): m.insert(id)
        }
    }

    func disarm(_ id: SensorID) {
        switch storage {
        case .none: break
        case .defaults(let suite):
            // Flushed too: a crash (from any cause) before CFPreferences' async flush would leave this marker set
            // and disable an innocent sensor at the next launch (final review S-M7).
            guard let d = Self.defaults(suite) else { return }
            d.removeObject(forKey: Self.keyPrefix + id.rawValue)
            d.synchronize()
        case .memory(let m): m.remove(id)
        }
    }

    /// Settings "Re-enable sensors": clears every marker (takes effect at the next engine start).
    public func reenableAll() {
        switch storage {
        case .none: break
        case .defaults(let suite):
            guard let d = Self.defaults(suite) else { return }
            for id in SensorID.allCases { d.removeObject(forKey: Self.keyPrefix + id.rawValue) }
        case .memory(let m): m.removeAll()
        }
    }

    private static func defaults(_ suite: String?) -> UserDefaults? {
        guard let suite else { return .standard }
        return UserDefaults(suiteName: suite)
    }
}
