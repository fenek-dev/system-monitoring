import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import Observation

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

    /// Ruling: "Top CPU · 37% of system" (CPU, GPU), "Top Disk · 205 MB/s I/O", "Top Thermals · 61°C" (a
    /// temperature is no total), else "Top Memory · 15.1 GB total"; nil total → "Top CPU".
    nonisolated static func header(_ category: MonitorModel.Category, total: String?) -> String {
        let title = headerTitle(category)
        guard let detail = headerDetail(category, total: total) else { return title }
        return "\(title) · \(detail)"
    }

    nonisolated static func headerTitle(_ category: MonitorModel.Category) -> String { "Top \(category.ttTitle)" }

    nonisolated static func headerDetail(_ category: MonitorModel.Category, total: String?) -> String? {
        guard let total else { return nil }
        switch category {
        case .cpu, .gpu: return "\(total) of system"
        case .disk: return "\(total) I/O"
        case .thermals: return total
        case .memory, .network, .power: return "\(total) total"
        }
    }

    /// Caption under the header (only with lines): CPU app values are per core, Thermals ranks by power.
    nonisolated static func caption(_ category: MonitorModel.Category) -> String? {
        switch category {
        case .cpu: "% of one core"
        case .thermals: "by power"
        default: nil
        }
    }

    /// Ruling: while the pointer is in the flyout the row order is frozen. Lines of `previous` still in `ranking`
    /// keep their order with fresh values and shares; apps new to the top `limit` are appended; capped at `limit`.
    /// `ranking` is the full, unlimited ranking.
    nonisolated static func frozen(previous: [FlyoutLine], ranking: [FlyoutLine],
                                   limit: Int = FlyoutModel.limit) -> [FlyoutLine] {
        let fresh = Dictionary(ranking.map { ($0.identity.key, $0) }, uniquingKeysWith: { a, _ in a })
        var out = previous.compactMap { fresh[$0.identity.key] }
        let kept = Set(out.map(\.identity.key))
        out += ranking.prefix(max(limit, 0)).filter { !kept.contains($0.identity.key) }
        return Array(out.prefix(max(limit, 0)))
    }

    /// VoiceOver announcement after the flyout shows: header plus the top 3 lines.
    nonisolated static func announcement(_ category: MonitorModel.Category, total: String?, lines: [FlyoutLine],
                                         units: UnitPreferences) -> String {
        var parts = [header(category, total: total)]
        if lines.isEmpty { parts.append("No app activity") }
        parts += lines.prefix(3).map { "\($0.name), \(format($0.value, category, units: units))" }
        return parts.joined(separator: ". ")
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
/// Not `live.topApps`: that cache drops `.other` before ranking, but the share needs Σ over all apps, and the
/// freeze needs the full ranking with values.
@MainActor
final class FlyoutLinesCache {
    private struct Key: Equatable {
        var version: Int
        var category: MonitorModel.Category
        var frozen: Bool
    }

    private var key: Key?
    private var cached: [FlyoutLine] = []
    private(set) var computations = 0

    /// `frozen`: the pointer is in the flyout → keep the displayed order (`FlyoutModel.frozen`).
    func lines(live: LiveModel, category: MonitorModel.Category, frozen: Bool = false) -> [FlyoutLine] {
        let k = Key(version: live.appsVersion, category: category, frozen: frozen)
        if k == key { return cached }
        let sameCategory = key?.category == category
        if frozen && sameCategory {
            let ranking = FlyoutModel.lines(apps: live.apps, category: category, limit: .max)
            cached = FlyoutModel.frozen(previous: cached, ranking: ranking)
        } else {
            cached = FlyoutModel.lines(apps: live.apps, category: category)
        }
        key = k
        computations += 1
        return cached
    }
}

/// Which row's flyout is shown (the App sets it); the popover row keeps `fillHover` while it is.
@MainActor @Observable
public final class FlyoutState {
    public var shown: MonitorModel.Category?

    public init(shown: MonitorModel.Category? = nil) {
        self.shown = shown
    }
}

/// The pointer over the flyout, fed by the App's AppKit tracking area (SwiftUI hover is unreliable in a never-key
/// panel). `location` is in `FlyoutPointer.space` (the flyout's root); `inside` changes only on enter/exit so the
/// flyout body (row-order freeze) does not re-render on every move.
@MainActor @Observable
public final class FlyoutPointer {
    public nonisolated static let space = "flyout"
    public var location: CGPoint?
    public var inside = false

    public init() {}
}
