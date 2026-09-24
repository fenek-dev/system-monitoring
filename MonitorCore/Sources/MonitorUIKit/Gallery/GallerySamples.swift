import MonitorModel
import SwiftUI

/// Gallery items reproduce reference-artboard regions with the artboards' sample values
/// (sizes in pt = the artboard region), so `telltale-render --component <id> --compare <crop>` lines up.
@MainActor enum GallerySamples {
    static var items: [TTGallery.Item] {
        [
            .init(id: "icons", size: CGSize(width: 560, height: 40)) { AnyView(IconsSample()) },
            .init(id: "type", size: CGSize(width: 560, height: 120)) { AnyView(TypeSample()) },
            // Main@2x: tile row at (240, 72), 1020×168.
            .init(id: "metric-tiles", size: CGSize(width: 1020, height: 168)) { AnyView(MetricTilesSample()) },
            // CPU@2x: stat strip at (240, 72), 1020×82.
            .init(id: "stat-strip", size: CGSize(width: 1020, height: 82)) { AnyView(StatStripSample()) },
            .init(id: "controls", size: CGSize(width: 1020, height: 120)) { AnyView(ControlsSample()) },
            .init(id: "bars", size: CGSize(width: 500, height: 150)) { AnyView(BarsSample()) },
            .init(id: "key-value", size: CGSize(width: 332, height: 170)) { AnyView(KeyValueSample()) },
            .init(id: "states", size: CGSize(width: 1020, height: 90)) { AnyView(StatesSample()) },
        ] + GalleryCharts.items
    }
}

private func onWindow<V: View>(_ v: V) -> some View {
    v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(TTColor.bgWindow)
}

private struct IconsSample: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach(TTIconName.allCases, id: \.self) { TTIcon($0, size: 16) }
        }
        .padding(12)
        .background(TTColor.bgCard)
    }
}

private struct TypeSample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("29").font(TTFont.display).foregroundStyle(TTColor.textPrimary)
                Text("%").font(TTFont.displayUnit).foregroundStyle(TTColor.textSecondary)
            }
            Text("Last 60 seconds").font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary)
            Text("P 4.12 GHz · E 2.59 GHz").font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
            Text("60 s ago").font(TTFont.micro).foregroundStyle(TTColor.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TTColor.bgCard)
    }
}

private struct MetricTilesSample: View {
    var body: some View {
        onWindow(
            HStack(spacing: TTSpace.gridGap) {
                TTMetricTile(category: .cpu, value: "29", unit: "%", detail: "P 4.12 GHz · E 2.59 GHz",
                             points: SampleSeries.wave(base: 0.29, amplitude: 0.05, seed: 1), unavailableReason: nil)
                TTMetricTile(category: .gpu, value: "22", unit: "%", detail: "1,180 MHz · 3.1 GB",
                             points: SampleSeries.wave(base: 0.12, amplitude: 0.05, seed: 2), unavailableReason: nil)
                TTMetricTile(category: .memory, value: "15.2", unit: "GB", detail: "of 24 GB · pressure normal",
                             points: SampleSeries.wave(base: 15.2, amplitude: 0.1, seed: 3), unavailableReason: nil,
                             yDomain: 0...24)
                TTMetricTile(category: .network, value: "11.1 MB/s", unit: "↓ ", detail: "↑ 1.6 MB/s · Wi-Fi",
                             points: SampleSeries.wave(base: 9, amplitude: 4, seed: 4, clamp: 0...40), unavailableReason: nil,
                             yDomain: 0...20)
                TTMetricTile(category: .thermals, value: "63", unit: "°C", detail: "SoC avg · fans 2,140 rpm",
                             points: SampleSeries.wave(base: 62, amplitude: 0.8, seed: 5), unavailableReason: nil)
            }
        )
    }
}

private struct StatStripSample: View {
    var body: some View {
        onWindow(
            TTStatStrip([
                .init(id: "total", label: "Total", value: "29", unit: "%", detail: "of 12 cores", tint: TTColor.cpu),
                .init(id: "user", label: "User", value: "22.1", unit: "%"),
                .init(id: "system", label: "System", value: "11.9", unit: "%"),
                .init(id: "idle", label: "Idle", value: "66.0", unit: "%"),
                .init(id: "load", label: "Load average", value: "4.12 · 3.80 · 3.55", detail: "1 · 5 · 15 min"),
                .init(id: "uptime", label: "Threads", value: nil, unavailableReason: "Not reported"),
            ])
        )
    }
}

private struct ControlsSample: View {
    @State var range = "Live"
    @State var metric = "CPU"
    var body: some View {
        onWindow(
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    TTSegmented(selection: $range, options: ["Live", "1H", "24H", "7D", "30D"].map { ($0, $0) })
                    TTSegmented(selection: $metric, options: ["CPU", "GPU", "Memory", "Network", "Disk", "Energy"].map { ($0, $0) },
                                compact: true)
                    TTIconButton(.pause, label: "Pause sampling") {}
                    TTIconButton(.settings, label: "Settings") {}
                    TTBadge("8 cores", dot: TTColor.cpu)
                    TTBadge("Active", level: .calm)
                }
                HStack(spacing: 8) {
                    Button("Quit") {}.buttonStyle(.tt(.smallSecondary))
                    Button("Force Quit") {}.buttonStyle(.tt(.smallDestructive))
                    Button("Cancel") {}.buttonStyle(.tt(.regularSecondary))
                    Button("Force Quit") {}.buttonStyle(.tt(.regularDestructive))
                    Button("Xcode build · 14:30") {}.buttonStyle(.tt(.chip))
                    TTLink("Open History") {}
                    TTIconButton(.ellipsis, label: "Actions for Xcode", variant: .rowAction) {}
                    TTIconButton(.eject, label: "Eject Macintosh HD", variant: .filled) {}
                    ForEach([16, 20, 26, 44] as [CGFloat], id: \.self) { s in
                        TTAppTile(identity: AppIdentity(key: AppKey(kind: .app, id: "com.apple.dt.Xcode"), displayName: "Xcode"),
                                  name: "Xcode", size: s)
                    }
                }
                HStack(spacing: 8) {
                    Button("Open Dashboard") {}.buttonStyle(.tt(.popoverPrimary)).frame(width: 220)
                    Button("History") {}.buttonStyle(.tt(.popoverSecondary))
                    TTIconButton(.quit, label: "Quit Telltale", variant: .footer) {}
                }
            }
            .padding(10)
        )
    }
}

private struct BarsSample: View {
    var body: some View {
        onWindow(
            VStack(alignment: .leading, spacing: 12) {
                TTProgressBar(value: 0.62, tint: TTColor.disk, thresholds: [], style: .medium)
                TTProgressBar(value: 0.34, tint: TTColor.gpu)
                TTSegmentBar([.init(10.4 / 18.6, TTColor.cpu), .init(4.1 / 18.6, TTColor.gpu), .init(0.2 / 18.6, TTColor.power),
                              .init(1.6 / 18.6, TTColor.dram)], style: .split, remainder: TTColor.fillRest)
                TTSegmentBar([.init(0.4, TTColor.mem), .init(0.12, TTColor.memWired), .init(0.08, TTColor.memCompressed),
                              .init(0.2, TTColor.memCached)], style: .composition, remainder: TTColor.fillFree)
                TTSegmentBar([.init(0.62, TTColor.disk), .init(0.05, TTColor.diskPurgeable)], style: .volume)
                TTThermalScale(levels: [
                    .init(title: "Nominal", detail: "full speed", color: TTColor.statusCalm),
                    .init(title: "Fair", detail: "light throttling", color: TTColor.statusFair),
                    .init(title: "Serious", detail: "throttling", color: TTColor.statusElevated),
                    .init(title: "Critical", detail: "heavy throttling", color: TTColor.statusCritical),
                ], current: 0)
            }
            .padding(10)
        )
    }
}

private struct KeyValueSample: View {
    var body: some View {
        onWindow(
            TTCard {
                TTCardHeader("Swap", icon: "memory") { TTCaption("macOS managed") }
                TTKeyValueList(rows: [
                    .init("Used", "1.20 GB"),
                    .init("Allocated", "2.00 GB"),
                    .init("IPv4", "192.168.1.24", mono: true),
                    .init("Compression", nil, unavailableReason: "Not reported"),
                ])
            }
        )
    }
}

private struct StatesSample: View {
    var body: some View {
        onWindow(
            HStack(spacing: 12) {
                TTCard { TTEmptyState(.collecting(since: nil)).frame(height: 40) }
                TTCard { TTEmptyState(.empty("No GPU clients")).frame(height: 40) }
                TTCard { MetricValue(nil, unavailableReason: "Sensor not available on this Mac", font: TTFont.stat) }
                TTCard {
                    TTAreaChart(SampleSeries.wave(base: 50, amplitude: 20, seed: 9, gaps: 25..<32), color: TTColor.cpu,
                                yDomain: 0...100, fillOpacity: TTChartFill.sparkline).frame(height: 40)
                }
            }
        )
    }
}
