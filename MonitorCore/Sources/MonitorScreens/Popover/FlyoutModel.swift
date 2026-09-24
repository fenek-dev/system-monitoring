import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit

/// One app line of the popover's top-apps flyout (DESIGN §2.22 "Flyout").
public struct FlyoutLine: Equatable, Sendable {
    public var identity: AppIdentity
    public var name: String
    /// The category's app metric (`TTPopoverRow.metricValue`).
    public var value: Double
    /// `value` / Σ of the metric over every app (0…1); the share bar's fill.
    public var share: Double
}

/// Pure bindings of the flyout: ranking, share maths, header copy.
enum FlyoutModel {
    static let limit = 10

    /// Top `limit` app groups by the category's metric (same metric as the popover's former top-3 lines), descending;
    /// equal values keep their input order. `share` is relative to the sum over ALL apps with a value (`.other`
    /// included in the sum but never listed). nil, zero and non-finite values are neither listed nor summed.
    nonisolated static func lines(apps: [AppSample], category: MonitorModel.Category,
                                  limit: Int = FlyoutModel.limit) -> [FlyoutLine] {
        var total = 0.0
        var ranked: [(index: Int, app: AppSample, value: Double)] = []
        for (i, app) in apps.enumerated() {
            guard let v = TTPopoverRow.metricValue(app, category), v.isFinite, v > 0 else { continue }
            total += v
            if app.identity.key != .other { ranked.append((i, app, v)) }
        }
        ranked.sort { $0.value != $1.value ? $0.value > $1.value : $0.index < $1.index }
        return ranked.prefix(max(limit, 0)).map {
            FlyoutLine(identity: $0.app.identity, name: $0.app.identity.displayName, value: $0.value,
                       share: $0.value / total)
        }
    }

    nonisolated static func format(_ v: Double, _ category: MonitorModel.Category, units: UnitPreferences) -> String {
        TTPopoverRow.format(v, category, units: units)
    }

    /// "Top CPU · 34% total"; Thermals' headline is a temperature, so no "total"; nil total → "Top CPU".
    nonisolated static func header(_ category: MonitorModel.Category, total: String?) -> String {
        let title = headerTitle(category)
        guard let detail = headerDetail(category, total: total) else { return title }
        return "\(title) · \(detail)"
    }

    nonisolated static func headerTitle(_ category: MonitorModel.Category) -> String { "Top \(category.ttTitle)" }

    nonisolated static func headerDetail(_ category: MonitorModel.Category, total: String?) -> String? {
        guard let total else { return nil }
        return category == .thermals ? total : "\(total) total"
    }

    /// The system value the header shows: the popover row's headline for CPU, GPU, Memory, Power and Thermals;
    /// ↓+↑ for Network and read+write for Disk (the metric the apps are ranked by — the Disk row shows free space).
    /// nil when unavailable.
    @MainActor static func total(_ category: MonitorModel.Category, live: LiveModel, units: UnitPreferences) -> String? {
        let text: String
        switch category {
        case .cpu: text = TTFormat.percent(live.cpu.usage)
        case .gpu: text = TTFormat.percent(live.gpu.usage)
        case .memory: text = TTFormat.memory(live.memory.used, style: .headline)
        case .network: text = TTFormat.rate(TTPopoverRow.sum(live.network.rxBps, live.network.txBps), units: units)
        case .thermals: text = TTFormat.temperature(live.thermals.socAverage, units: units)
        case .power: text = TTFormat.watts(W5a.packageWatts(live.power) ?? live.power.systemWatts)
        case .disk: text = TTFormat.diskRate(TTPopoverRow.sum(live.disk.readBps, live.disk.writeBps))
        }
        return text == TTFormat.unavailable ? nil : text
    }
}

/// Per-`appsVersion` ranking cache for `FlyoutView`: the body reads it every render, the sort runs once per apps
/// update (and category switch). Reading `live.appsVersion` registers the observation that re-renders each tick.
@MainActor
final class FlyoutLinesCache {
    private struct Key: Equatable {
        var version: Int
        var category: MonitorModel.Category
    }

    private var key: Key?
    private var cached: [FlyoutLine] = []
    private(set) var computations = 0

    func lines(live: LiveModel, category: MonitorModel.Category) -> [FlyoutLine] {
        let k = Key(version: live.appsVersion, category: category)
        if k == key { return cached }
        cached = FlyoutModel.lines(apps: live.apps, category: category)
        key = k
        computations += 1
        return cached
    }
}
