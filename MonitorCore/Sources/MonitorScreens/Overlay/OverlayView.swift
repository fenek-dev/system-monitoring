import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// One overlay column: "CPU 34%" over "↓8 ↑91 ø22" (spec 2026-09-25 overlay §UI).
public struct OverlayMetric: Equatable, Sendable {
    public var label: String
    /// Category colour of the label.
    public var labelColor: Color
    public var value: String
    /// Value colour: `textPrimary`, memory pressure, or `textTertiary` when unavailable.
    public var tint: Color
    /// "↓min ↑max øavg", "—" below 2 samples, "— — —" when unavailable.
    public var stats: String
    /// VoiceOver summary of the column: "CPU 37%, last minute low 29, high 48, average 35"; "CPU unavailable".
    public var accessibilityLabel: String
}

/// Click-through on-screen overlay: CPU, GPU and memory with their rolling 60-s min / max / avg.
/// Dark always, no animation; values change in place. Reads `LiveModel` from the environment.
public struct OverlayView: View {
    @Environment(LiveModel.self) private var live
    private let opacity: Double

    public init(opacity: Double = 0.85) {
        self.opacity = opacity
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Self.metrics(live: live), id: \.label) { m in
                let template = Self.template(m.label)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(m.label).font(TTFont.captionMedium).foregroundStyle(m.labelColor)
                        Self.fixedWidth(Text(m.value).foregroundStyle(m.tint), template: template.value)
                            .font(TTFont.body13Value)
                    }
                    Self.fixedWidth(Text(m.stats).foregroundStyle(TTColor.textSecondary), template: template.stats)
                        .font(TTFont.micro)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(m.accessibilityLabel)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(TTColor.bgElevated.opacity(opacity)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TTColor.separator))
        .fixedSize()
        .opacity(Self.contentOpacity(live: live))
        .transaction { $0.disablesAnimations = true }
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Fixed size

    /// Worst-case strings per column (coordinator ruling): each column is at least this wide, so the overlay keeps
    /// one size while values change.
    static func template(_ label: String) -> (value: String, stats: String) {
        label == "MEM" ? ("999.9 GB", "↓999.9 ↑999.9 ø999.9") : ("100%", "↓100 ↑100 ø100")
    }

    /// `text` over a hidden `template` in the same font: width = max(template, text), measured by layout.
    private static func fixedWidth(_ text: some View, template: String) -> some View {
        ZStack(alignment: .leading) {
            Text(template).hidden()
            text
        }
    }

    // MARK: - Pure presentation

    static let unavailableStats = "— — —"

    /// The three columns. Views observe `LiveModel` only through this (cpu/gpu/memory + their series).
    @MainActor public static func metrics(live: LiveModel) -> [OverlayMetric] {
        let health = live.sensorHealth
        let mem = live.memory
        let memTint: Color = switch mem.pressureLevel {
        case .warning?: TTColor.statusElevated
        case .critical?: TTColor.statusCritical
        case .normal?, nil: TTColor.textPrimary
        }
        return [
            metric("CPU", "CPU", TTColor.cpu, .cpuUsage, live: live, health: health,
                   value: live.cpu.usage.map { TTFormat.percent($0) }, stats: percentStats, spoken: percentNumber),
            metric("GPU", "GPU", TTColor.gpu, .gpuUsage, live: live, health: health,
                   value: live.gpu.usage.map { TTFormat.percent($0) }, stats: percentStats, spoken: percentNumber),
            metric("MEM", "Memory", TTColor.mem, .memUsed, live: live, health: health,
                   value: mem.used.map { TTFormat.memory($0, style: .headline) }, stats: memoryStats,
                   spoken: { TTFormat.memory(bytes($0), style: .headline) }, tint: memTint),
        ]
    }

    /// 0.5 while sampling is paused (same test as the popover and page header), else 1.
    @MainActor static func contentOpacity(live: LiveModel) -> Double {
        live.isPausedPhase ? 0.5 : 1
    }

    @MainActor private static func metric(_ label: String, _ name: String, _ color: Color, _ series: HistoryMetric,
                                          live: LiveModel, health: [SensorID: SensorStatus], value: String?,
                                          stats format: (OverlayStats) -> String, spoken: (Double) -> String,
                                          tint: Color = TTColor.textPrimary) -> OverlayMetric {
        if unavailableReason(series, health: health) != nil {
            return OverlayMetric(label: label, labelColor: color, value: TTFormat.unavailable, tint: TTColor.textTertiary,
                                 stats: unavailableStats, accessibilityLabel: "\(name) unavailable")
        }
        let points = live.chartSeries(series)
        let computed = points.last.flatMap { OverlayStats.compute(points, now: $0.time) }
        let stats = computed.map(format) ?? TTFormat.unavailable
        guard let value, value != TTFormat.unavailable else {
            // Sensors usable but no value yet (first tick: rates need two samples).
            return OverlayMetric(label: label, labelColor: color, value: TTFormat.unavailable, tint: TTColor.textTertiary,
                                 stats: stats, accessibilityLabel: "\(name) collecting")
        }
        var a11y = "\(name) \(value)"
        if let s = computed {
            a11y += ", last minute low \(spoken(s.min)), high \(spoken(s.max)), average \(spoken(s.avg))"
        }
        return OverlayMetric(label: label, labelColor: color, value: value, tint: tint, stats: stats,
                             accessibilityLabel: a11y)
    }

    private static func percentNumber(_ fraction: Double) -> String { TTFormat.number(fraction * 100, digits: 0) }
    private static func bytes(_ v: Double) -> UInt64 { UInt64(Swift.max(v, 0).rounded()) }

    /// Fractions as integer percent without the sign: "↓8 ↑91 ø22".
    static func percentStats(_ s: OverlayStats) -> String {
        row(s, percentNumber)
    }

    /// Bytes as headline GB without the unit (R6): "↓14.8 ↑16.1 ø15.3".
    static func memoryStats(_ s: OverlayStats) -> String {
        row(s) { TTFormat.memoryNumber(bytes($0)) }
    }

    private static func row(_ s: OverlayStats, _ f: (Double) -> String) -> String {
        "↓\(f(s.min)) ↑\(f(s.max)) ø\(f(s.avg))"
    }
}
