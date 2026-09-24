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
            // Thermals@2x "Thermal pressure" card at (240, 168): 1020 wide.
            .init(id: "thermal-scale", size: CGSize(width: 1020, height: 110)) { AnyView(ThermalScaleCard()) },
            // DESIGN §3.15: collecting (first launch) vs unavailable (sensor missing).
            .init(id: "tile-states", size: CGSize(width: 676, height: 290)) { AnyView(TileStatesSample()) },
        ]
    }
}

private struct ThermalScaleCard: View {
    var body: some View {
        TTCard(spacing: TTSpace.x10) {
            TTCardHeader("Thermal pressure") { TTCaption("Reported by macOS · changes are logged to History") }
            TTThermalScale(levels: [
                .init(title: "Nominal", detail: "Full performance", color: TTColor.statusCalm),
                .init(title: "Fair", detail: "Mild fan boost", color: TTColor.statusFair),
                .init(title: "Serious", detail: "Clock limiting likely", color: TTColor.statusElevated),
                .init(title: "Critical", detail: "Heavy throttling", color: TTColor.statusCritical),
            ], current: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TTColor.bgWindow)
    }
}

private struct TileStatesSample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TTSpace.gridGap) {
            HStack(spacing: TTSpace.gridGap) {
                TTMetricTile(category: .gpu, value: nil, unit: "%", detail: "1,180 MHz", points: [], unavailableReason: nil)
                TTMetricTile(category: .thermals, value: nil, unit: "°C", detail: "SoC avg", points: [],
                             unavailableReason: "Sensor not available on this Mac")
            }
            TTCard(spacing: TTSpace.x4) {
                TTTimelineRow(label: "GPU", icon: nil, value: nil, points: [], color: TTColor.gpu, yDomain: 0...1)
                TTTimelineRow(label: "Thermals", icon: nil, value: nil, unavailableReason: "Sensor not available on this Mac",
                              points: [], color: TTColor.thermal, yDomain: 0...100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(TTColor.bgWindow)
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
