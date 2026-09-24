import MonitorModel
import SwiftUI

/// DESIGN §2.6 per-core cluster bars: grid of `cores.count` equal columns, gap 10; each column VStack
/// (center, gap 6): value `body12Strong` ("72%"), track (width ≤ 44, height 104, radius 6, `fillTrack`) clipping a
/// bottom-aligned fill (height = usage, radius 4, `color`), label `caption` `textSecondary` ("P1"… / "E1"…).
/// Height changes animate `.easeOut(0.25)` (not in snapshots).
public struct TTCoreBars: View, Equatable {
    let cores: [CoreUsage]
    let kind: CoreKind
    let color: Color
    @Environment(\.isSnapshot) private var isSnapshot

    public init(cores: [CoreUsage], kind: CoreKind, color: Color) {
        self.cores = cores
        self.kind = kind
        self.color = color
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.cores == b.cores && a.kind == b.kind && a.color == b.color
    }

    var prefix: String { kind == .performance ? "P" : "E" }

    public var body: some View {
        HStack(alignment: .top, spacing: TTSpace.x10) {
            ForEach(cores.indices, id: \.self) { i in
                let usage = min(max(cores[i].usage.isFinite ? cores[i].usage : 0, 0), 1)
                VStack(spacing: TTSpace.x6) {
                    Text(TTFormat.percent(usage))
                        .font(TTFont.body12Strong)
                        .foregroundStyle(TTColor.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous).fill(TTColor.fillTrack)
                        RoundedRectangle(cornerRadius: TTRadius.r4, style: .continuous)
                            .fill(color)
                            .frame(height: 104 * usage)
                    }
                    .frame(maxWidth: 44)
                    .frame(height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: TTRadius.r6, style: .continuous))
                    .animation(isSnapshot ? nil : .easeOut(duration: 0.25), value: usage)
                    Text("\(prefix)\(i + 1)")
                        .font(TTFont.caption)
                        .foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(prefix)\(i + 1) \(TTFormat.percent(usage))")
            }
        }
    }
}
