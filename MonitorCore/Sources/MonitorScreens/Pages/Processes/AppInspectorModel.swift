import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import Observation
import SwiftUI

/// App detail "Activity" lanes (DESIGN §3.12): CPU (% of one core, auto ≥ 100), GPU, Memory, Network (↓+↑),
/// Disk (R+W), Energy (W).
public enum InspectorLane: String, CaseIterable, Sendable {
    case cpu, gpu, memory, network, disk, energy

    public var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .network: "Network"
        case .disk: "Disk"
        case .energy: "Energy"
        }
    }

    public var metrics: [AppMetric] {
        switch self {
        case .cpu: [.cpu]
        case .gpu: [.gpu]
        case .memory: [.memory]
        case .network: [.netRx, .netTx]
        case .disk: [.diskRead, .diskWrite]
        case .energy: [.energy]
        }
    }

    public var color: Color {
        switch self {
        case .cpu: TTColor.cpu
        case .gpu: TTColor.gpu
        case .memory: TTColor.mem
        case .network: TTColor.net
        case .disk: TTColor.disk
        case .energy: TTColor.power
        }
    }

    public var icon: TTIconName {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        case .energy: .power
        }
    }

    public var column: ProcessColumn {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        case .energy: .energy
        }
    }

    /// y-domain for the window (DESIGN §5.10: per-app auto "nice" ceilings; CPU ≥ 100; GPU 0–100).
    public func domain(_ points: [SeriesPoint]) -> ClosedRange<Double> {
        let top = points.compactMap(\.value).max() ?? 0
        switch self {
        case .cpu: return 0...max(100, TTFormat.niceCeiling(top, minimum: 100))
        case .gpu: return 0...100
        case .memory:
            let gib = 1_073_741_824.0
            return 0...(TTFormat.niceCeiling(top / gib, minimum: 1) * gib)
        case .network, .disk: return 0...TTFormat.niceRateCeiling(top)
        case .energy: return 0...TTFormat.niceCeiling(top, minimum: 1)
        }
    }

    /// Current value text for the row (the app's or process's own live value).
    public func valueText(_ row: ProcessRow, units: UnitPreferences) -> String? {
        guard let v = row.value(column) else { return nil }
        switch self {
        case .cpu, .gpu: return TTFormat.cpuPercent(v)
        case .memory: return TTFormat.bytes(row.memory)
        case .network: return TTFormat.rate(v, units: units)
        case .disk: return TTFormat.diskRate(v)
        case .energy: return TTFormat.appWatts(v)
        }
    }
}

/// Inspector state: detail range, stored per-app series (non-Live ranges), a small live ring for a selected
/// process (Processes mode: there are no per-process series in the model or store).
@MainActor @Observable
public final class AppInspectorModel {
    public var range: HistoryRange = .live
    public private(set) var stored: [InspectorLane: [SeriesPoint]] = [:]
    /// (app, range, end) the stored series belong to.
    public private(set) var storedKey: StoredKey?
    public private(set) var loadError: String?

    public struct StoredKey: Hashable, Sendable {
        public var app: AppKey
        public var range: HistoryRange
        public var end: Date
    }

    @ObservationIgnored private var ring: [InspectorLane: [SeriesPoint]] = [:]
    @ObservationIgnored private var ringOwner: ProcessID?
    @ObservationIgnored private var ringLast: Date?
    public nonisolated static let ringCapacity = 60

    public init() {}

    /// Live points for a lane: `LiveModel.appSeries` for app rows (↓+↑ and R+W summed per sample); the local
    /// ring for process rows.
    public func livePoints(_ lane: InspectorLane, row: ProcessRow, live: LiveModel) -> [SeriesPoint] {
        switch row.rowKind {
        case .app:
            let series = lane.metrics.map { live.appSeries(row.appKey, $0) }
            return Self.sum(series)
        case .process:
            return ringOwner == processID(row) ? ring[lane] ?? [] : []
        case .restrictedSummary:
            return []
        }
    }

    public func points(_ lane: InspectorLane, row: ProcessRow, live: LiveModel) -> [SeriesPoint] {
        if range == .live { return livePoints(lane, row: row, live: live) }
        guard storedKey?.app == row.appKey, storedKey?.range == range else { return [] }
        return stored[lane] ?? []
    }

    /// Appends the selected process's values once per frame (idempotent per `time`). Ring storage is not
    /// observed, so calling this from `body` does not invalidate the view.
    public func record(_ row: ProcessRow?, at time: Date?) {
        guard let row, row.rowKind == .process, let time, let id = processID(row) else { return }
        if ringOwner != id {
            ring = [:]
            ringOwner = id
            ringLast = nil
        }
        guard ringLast != time else { return }
        ringLast = time
        for lane in InspectorLane.allCases {
            var pts = ring[lane] ?? []
            pts.append(SeriesPoint(time: time, value: row.value(lane.column)))
            if pts.count > Self.ringCapacity { pts.removeFirst(pts.count - Self.ringCapacity) }
            ring[lane] = pts
        }
    }

    /// Loads the stored per-app series for a non-Live range (`historyProvider.appSeries`, display bucket).
    public func load(app: AppKey, range: HistoryRange, end: Date, provider: any HistoryProvider) async {
        guard range != .live else { return }
        let key = StoredKey(app: app, range: range, end: end)
        if storedKey == key { return }
        do {
            let metrics = InspectorLane.allCases.flatMap(\.metrics)
            let result = try await provider.appSeries(app, metrics, range: range, end: end)
            guard !Task.isCancelled else { return }
            var lanes: [InspectorLane: [SeriesPoint]] = [:]
            for lane in InspectorLane.allCases {
                lanes[lane] = Self.sum(lane.metrics.map { result[$0] ?? [] })
            }
            stored = lanes
            storedKey = key
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            stored = [:]
            storedKey = key
            loadError = "\(error)"
        }
    }

    /// Connections for the row: the app's flows, or the process's own in Processes mode; busiest first.
    public nonisolated static func connections(_ all: [ConnectionSample], for row: ProcessRow) -> [ConnectionSample] {
        let mine: [ConnectionSample]
        switch row.rowKind {
        case .app: mine = all.filter { $0.app == row.appKey }
        case .process: mine = all.filter { $0.process.pid == row.pid && row.pid != nil }
        case .restrictedSummary: mine = []
        }
        return mine.sorted { a, b in
            let x = (a.rxBps ?? 0) + (a.txBps ?? 0), y = (b.rxBps ?? 0) + (b.txBps ?? 0)
            return x != y ? x > y : a.id < b.id
        }
    }

    /// Pointwise sum; a point is a gap only when every input is a gap there. Aligns by index (same window).
    public nonisolated static func sum(_ series: [[SeriesPoint]]) -> [SeriesPoint] {
        guard let first = series.first else { return [] }
        guard series.count > 1 else { return first }
        let n = series.map(\.count).min() ?? 0
        return (0..<n).map { i in
            let values = series.compactMap { $0[$0.count - n + i].value }
            return SeriesPoint(time: first[first.count - n + i].time, value: values.isEmpty ? nil : values.reduce(0, +))
        }
    }

    private func processID(_ row: ProcessRow) -> ProcessID? {
        if case .process(let id) = row.id { return id }
        return nil
    }
}
