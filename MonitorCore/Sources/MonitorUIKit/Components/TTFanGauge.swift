import MonitorModel
import SwiftUI

/// DESIGN §2.17 fan gauge: 76×76, center (38,38), r 30, stroke 7, round caps; 270° track (white @ 0.08) from 7:30
/// clockwise to 4:30; value arc `thermal`, length 270°·rpm/maxRPM (animates `.easeOut(0.4)`); `fan` glyph 18
/// (stroke 1.4) `textSecondary` in the center. Right of it (gap 14) a VStack gap 2: name `body12` `textSecondary`,
/// "2,140 rpm" `statMedium`, "max 5,700" `caption` `textTertiary`.
public struct TTFanGauge: View, Equatable {
    let fan: FanSnapshot
    @Environment(\.isSnapshot) private var isSnapshot

    public init(fan: FanSnapshot) { self.fan = fan }

    public nonisolated static func == (a: Self, b: Self) -> Bool { a.fan == b.fan }

    nonisolated static func fraction(_ fan: FanSnapshot) -> Double {
        guard fan.maxRPM > 0, fan.rpm.isFinite else { return 0 }
        return min(max(fan.rpm / fan.maxRPM, 0), 1)
    }

    public var body: some View {
        HStack(spacing: TTSpace.x14) {
            ZStack {
                GaugeArc(fraction: 1).stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: TTStroke.gauge, lineCap: .round))
                GaugeArc(fraction: Self.fraction(fan))
                    .stroke(TTColor.thermal, style: StrokeStyle(lineWidth: TTStroke.gauge, lineCap: .round))
                    .animation(isSnapshot ? nil : .easeOut(duration: 0.4), value: Self.fraction(fan))
                TTIcon(.fan, size: 18, color: TTColor.textSecondary, gridStroke: TTStroke.iconFan)
            }
            .frame(width: 76, height: 76)
            VStack(alignment: .leading, spacing: TTSpace.x2) {
                Text(fan.name).font(TTFont.body12).foregroundStyle(TTColor.textSecondary).lineLimit(1)
                Text(TTFormat.rpm(fan.rpm)).font(TTFont.statMedium).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                Text(TTFormat.maxRPM(fan.maxRPM)).font(TTFont.caption).foregroundStyle(TTColor.textTertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 270° arc starting at 135° (7:30, clockwise from 3 o'clock), `fraction` of the sweep; r 30 in a 76 frame.
    struct GaugeArc: Shape {
        var fraction: Double
        var animatableData: Double {
            get { fraction }
            set { fraction = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var p = Path()
            guard fraction > 0 else { return p }
            let s = min(rect.width, rect.height) / 76
            p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: 30 * s,
                     startAngle: .degrees(135), endAngle: .degrees(135 + 270 * fraction), clockwise: false)
            return p
        }
    }
}
