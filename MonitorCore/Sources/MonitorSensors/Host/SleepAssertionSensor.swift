import Foundation
import IOKit.pwr_mgt
import MonitorModel

// MARK: - Parse layer (pure)

enum SleepAssertionParser {
    /// Legacy names IOPMLib.h documents as aliases of the modern types (`kIOPMAssertionTypeNoIdleSleep`,
    /// `kIOPMAssertionTypeNoDisplaySleep`; findings/extras.md §3).
    static let aliases: [String: String] = [
        "NoIdleSleepAssertion": "PreventUserIdleSystemSleep",
        "NoDisplaySleepAssertion": "PreventUserIdleDisplaySleep",
    ]

    /// Canonical IOPMLib.h types that keep the Mac (or its display) awake — what "Preventing sleep" means.
    static let sleepPreventing: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
    ]

    static func canonical(_ type: String) -> String { aliases[type] ?? type }

    /// `IOPMCopyAssertionsByProcess` → pid: sorted, unique canonical sleep-preventing types.
    /// An assertion made on behalf of another process (`AssertionOnBehalfOfPID`, e.g. coreaudiod for an app
    /// playing audio) is attributed to that process, like Activity Monitor. Released assertions
    /// (`AssertLevel` 0) and non-preventing types (UserIsActive, BackgroundTask, …) are skipped.
    static func reading(_ byProcess: [AnyHashable: Any]) -> SleepAssertionsReading {
        var out: [Int32: Set<String>] = [:]
        for (key, value) in byProcess {
            guard let owner = pid(key), let list = value as? [[String: Any]] else { continue }
            for a in list {
                guard let type = a["AssertType"] as? String else { continue }
                if let level = (a["AssertLevel"] as? NSNumber)?.intValue, level == 0 { continue }
                let c = canonical(type)
                guard sleepPreventing.contains(c) else { continue }
                let target = (a["AssertionOnBehalfOfPID"] as? NSNumber).map { $0.int32Value }.flatMap { $0 > 0 ? $0 : nil } ?? owner
                out[target, default: []].insert(c)
            }
        }
        return SleepAssertionsReading(byPID: out.mapValues { $0.sorted() })
    }

    private static func pid(_ key: AnyHashable) -> Int32? {
        if let n = key.base as? NSNumber { return n.int32Value }
        if let s = key.base as? String { return Int32(s) }
        if let i = key.base as? Int { return Int32(exactly: i) }
        return nil
    }
}

// MARK: - FFI layer

enum SleepAssertionFFI {
    static func copyByProcess() throws(SensorError) -> [AnyHashable: Any] {
        var dict: Unmanaged<CFDictionary>?
        let kr = IOPMCopyAssertionsByProcess(&dict)
        guard kr == kIOReturnSuccess else { throw w6aIOReturnError(kr, "IOPMCopyAssertionsByProcess") }
        guard let d = dict?.takeRetainedValue() else { return [:] }   // no assertions at all
        guard let typed = d as? [AnyHashable: Any] else { throw SensorError.transient("IOPMCopyAssertionsByProcess: unexpected type") }
        return typed
    }
}

// MARK: - Sensor

/// Per-process sleep-preventing power assertions (`IOPMCopyAssertionsByProcess`, no root).
public final class SleepAssertionSensor: Sensor {
    public typealias Reading = SleepAssertionsReading
    public let id = SensorID.sleepAssertions
    public let cadence = SensorCadence.every(.seconds(5), background: .seconds(60))

    public init() {}

    public func prepare() throws(SensorError) {}

    public func sample(_ ctx: SampleContext) throws(SensorError) -> (reading: SleepAssertionsReading, capturedNs: UInt64) {
        let raw = try SleepAssertionFFI.copyByProcess()
        return (SleepAssertionParser.reading(raw), w6aUptimeNs())
    }

    public func invalidate() {}
}
