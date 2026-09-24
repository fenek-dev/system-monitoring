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
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(m.label).font(TTFont.captionMedium).foregroundStyle(m.labelColor)
                        Text(m.value).font(TTFont.body13Value).foregroundStyle(m.tint)
                    }
                    Text(m.stats).font(TTFont.micro).foregroundStyle(TTColor.textSecondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(TTColor.bgElevated.opacity(opacity)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TTColor.separator))
        .fixedSize()
        .transaction { $0.disablesAnimations = true }
        .environment(\.colorScheme, .dark)
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
            metric("CPU", TTColor.cpu, .cpuUsage, live: live, health: health,
                   value: live.cpu.usage.map { TTFormat.percent($0) }, stats: percentStats),
            metric("GPU", TTColor.gpu, .gpuUsage, live: live, health: health,
                   value: live.gpu.usage.map { TTFormat.percent($0) }, stats: percentStats),
            metric("MEM", TTColor.mem, .memUsed, live: live, health: health,
                   value: mem.used.map { TTFormat.memory($0, style: .headline) }, stats: memoryStats, tint: memTint),
        ]
    }

    @MainActor private static func metric(_ label: String, _ color: Color, _ series: HistoryMetric, live: LiveModel,
                                          health: [SensorID: SensorStatus], value: String?,
                                          stats format: (OverlayStats) -> String,
                                          tint: Color = TTColor.textPrimary) -> OverlayMetric {
        if unavailableReason(series, health: health) != nil {
            return OverlayMetric(label: label, labelColor: color, value: TTFormat.unavailable, tint: TTColor.textTertiary,
                                 stats: unavailableStats)
        }
        let points = live.chartSeries(series)
        let stats = points.last.flatMap { OverlayStats.compute(points, now: $0.time) }.map(format) ?? TTFormat.unavailable
        guard let value, value != TTFormat.unavailable else {
            return OverlayMetric(label: label, labelColor: color, value: TTFormat.unavailable, tint: TTColor.textTertiary,
                                 stats: stats)
        }
        return OverlayMetric(label: label, labelColor: color, value: value, tint: tint, stats: stats)
    }

    /// Fractions as integer percent without the sign: "↓8 ↑91 ø22".
    static func percentStats(_ s: OverlayStats) -> String {
        row(s) { TTFormat.number($0 * 100, digits: 0) }
    }

    /// Bytes as headline GB without the unit (R6): "↓14.8 ↑16.1 ø15.3".
    static func memoryStats(_ s: OverlayStats) -> String {
        row(s) { TTFormat.memoryNumber(UInt64(Swift.max($0, 0).rounded())) }
    }

    private static func row(_ s: OverlayStats, _ f: (Double) -> String) -> String {
        "↓\(f(s.min)) ↑\(f(s.max)) ø\(f(s.avg))"
    }
}
