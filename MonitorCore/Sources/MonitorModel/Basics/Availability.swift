import Foundation

// Tooltip text for "—" values (ARCHITECTURE §5.5, §6). A metric is unavailable when none of its source
// sensors is usable; `.ok`, `.degraded` and "no status yet" count as usable.

/// Reason a system metric is missing, or nil when at least one source sensor is usable.
public func unavailableReason(_ metric: HistoryMetric, health: [SensorID: SensorStatus]) -> String? {
    sensorReason(metric.sources, health: health)
}

/// Reason a process row shows "—" for `metric`, or nil when the row has a value.
public func unavailableReason(_ metric: AppMetric, _ process: ProcessSample, health: [SensorID: SensorStatus]) -> String? {
    guard process.value(for: metric) == nil else { return nil }
    if let reason = sensorReason(metric.sources, health: health) { return reason }
    if process.provenance == .restricted {
        switch metric {
        case .cpu, .diskRead, .diskWrite, .energy:
            return "Owned by another user; counted in its coalition row"
        case .memory:
            return "Appears when the process table is open"
        case .gpu, .netRx, .netTx:
            break
        }
    }
    return "Not available for this process"
}

/// Reason an app row shows "—" for `metric`, or nil when the app has a value.
public func unavailableReason(_ metric: AppMetric, _ app: AppSample, health: [SensorID: SensorStatus]) -> String? {
    guard app.value(for: metric) == nil else { return nil }
    if let reason = sensorReason(metric.sources, health: health) { return reason }
    if app.hiddenProcessCount > 0 {
        return "Owned by another user; counted in its coalition row"
    }
    return "Not available for this app"
}

/// First source's reason when every source is unavailable or disabled; nil otherwise.
private func sensorReason(_ sources: [SensorID], health: [SensorID: SensorStatus]) -> String? {
    var firstReason: String?
    for id in sources {
        switch health[id] {
        case nil, .ok?, .degraded?:
            return nil
        case .unavailable(let r)?, .disabled(let r)?:
            if firstReason == nil { firstReason = r }
        }
    }
    return firstReason
}
