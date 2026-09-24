import MonitorModel
import SwiftUI

/// Core bars (CPU@2x "Performance cores" at (240, 168), 676×236) and fan gauges (Thermals@2x "Fans" at (928, 289)).
@MainActor enum GalleryGauges {
    static var items: [TTGallery.Item] {
        [
            .init(id: "core-bars", size: CGSize(width: 676, height: 236)) { AnyView(CoreBarsCard()) },
            .init(id: "fan-gauges", size: CGSize(width: 332, height: 230)) { AnyView(FansCard()) },
            // History "App share" treemap (ADDED): ≈ 760×190.
            .init(id: "treemap", size: CGSize(width: 760, height: 190)) { AnyView(TreemapSample()) },
        ]
    }
}

private struct TreemapSample: View {
    static func share(_ name: String, _ value: Double, _ total: Double, kind: AppKey.Kind = .app) -> AppShare {
        AppShare(identity: AppIdentity(key: AppKey(kind: kind, id: kind == .other ? "other" : name), displayName: name),
                 value: value, fraction: value / total)
    }

    var body: some View {
        let t = 812.0 + 96 + 19 + 14 + 11 + 9 + 30
        TTTreemap([
            Self.share("Xcode", 812, t), Self.share("Final Cut Pro", 96, t), Self.share("Safari", 19, t),
            Self.share("WindowServer", 14, t), Self.share("Docker Desktop", 11, t), Self.share("mds_stores", 9, t),
            Self.share("Other", 30, t, kind: .other),
        ], metric: .cpu, animated: false, otherCount: 23)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TTColor.bgCard)
    }
}

private struct CoreBarsCard: View {
    let usages: [Double] = [0.70, 0.81, 0.47, 0.34, 0.34, 0.16, 0.15, 0.03]
    var body: some View {
        TTCard {
            TTCardHeader("Performance cores") { TTBadge("8 cores", dot: TTColor.cpu) }
            TTCoreBars(cores: usages.enumerated().map { CoreUsage(index: $0.offset, kind: .performance, usage: $0.element) },
                       kind: .performance, color: TTColor.cpu)
            HStack(spacing: TTSpace.x18) {
                Text("4.12 GHz of 4.51 GHz")
                Text("Active residency 58%")
                Text("Cluster power 8.9 W")
            }
            .font(TTFont.caption)
            .foregroundStyle(TTColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TTColor.bgWindow)
    }
}

private struct FansCard: View {
    var body: some View {
        TTCard {
            TTCardHeader("Fans", icon: "fan")
            TTFanGauge(fan: FanSnapshot(id: 0, name: "Left fan", rpm: 2_250, minRPM: 1_200, maxRPM: 5_700))
            TTFanGauge(fan: FanSnapshot(id: 1, name: "Right fan", rpm: 2_234, minRPM: 1_200, maxRPM: 5_700))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TTColor.bgWindow)
    }
}
