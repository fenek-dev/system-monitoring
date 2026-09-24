import MonitorModel
import SwiftUI

/// Chart gallery items (reference regions: Main "Last 60 seconds", CPU "Usage", Network "Throughput",
/// Thermals "Temperatures", GPU utilization).
@MainActor enum GalleryCharts {
    static var items: [TTGallery.Item] {
        [
            .init(id: "timeline-card", size: CGSize(width: 676, height: 276)) { AnyView(TimelineCard()) },
            .init(id: "cpu-usage", size: CGSize(width: 1020, height: 196)) { AnyView(CPUUsageCard()) },
            .init(id: "net-throughput", size: CGSize(width: 676, height: 268)) { AnyView(ThroughputCard()) },
            .init(id: "thermal-lines", size: CGSize(width: 676, height: 250)) { AnyView(TemperaturesCard()) },
            // GPU@2x "Utilization & frequency" at (240, 168): 676×249.
            .init(id: "gpu-dual", size: CGSize(width: 676, height: 249)) { AnyView(GPUCard()) },
        ]
    }
}

private let end = Date(timeIntervalSince1970: 1_790_257_000)

private func onWindow<V: View>(_ v: V) -> some View {
    v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(TTColor.bgWindow)
}

private struct TimelineCard: View {
    var body: some View {
        onWindow(
            TTCard {
                TTCardHeader("Last 60 seconds") { TTLink("Open History") {} }
                VStack(spacing: TTSpace.x4) {
                    TTTimelineRow(label: "CPU", value: "29%", points: SampleSeries.wave(base: 0.29, amplitude: 0.05, seed: 1),
                                  color: TTColor.cpu, yDomain: 0...1)
                    // Gap (paused 6 s): line and area break, no interpolation.
                    TTTimelineRow(label: "GPU", value: "22%",
                                  points: SampleSeries.wave(base: 0.13, amplitude: 0.05, seed: 2, gaps: 20..<26),
                                  color: TTColor.gpu, yDomain: 0...1)
                    TTTimelineRow(label: "Memory", value: "15.2 GB", points: SampleSeries.wave(base: 15.2, amplitude: 0.1, seed: 3),
                                  color: TTColor.mem, yDomain: 0...24)
                    TTTimelineRow(label: "Network", value: "11.1 MB/s", points: SampleSeries.wave(base: 9, amplitude: 4, seed: 4),
                                  color: TTColor.net, yDomain: 0...40)
                    TTTimelineRow(label: "Thermals", value: "63°C", points: SampleSeries.wave(base: 62, amplitude: 0.8, seed: 5),
                                  color: TTColor.thermal, yDomain: 0...100)
                }
                TTTimeAxis(range: .live, end: end).frame(width: 480).padding(.leading, 96)
            }
            .frame(minHeight: 276, alignment: .top)
        )
    }
}

private struct CPUUsageCard: View {
    var body: some View {
        let user = ChartSeries(id: "user", label: "User", color: TTColor.cpu,
                               points: SampleSeries.wave(base: 0.2, amplitude: 0.05, seed: 11), fillOpacity: TTChartFill.cpuUser)
        let system = ChartSeries(id: "system", label: "System", color: TTColor.cpuAlt,
                                 points: SampleSeries.wave(base: 0.12, amplitude: 0.03, seed: 12), fillOpacity: TTChartFill.cpuSystem)
        return onWindow(
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Usage") { TTLegend([user, system]) }
                TTStackedArea([user, system], yDomain: 0...1, outline: TTColor.cpuLine.opacity(TTChartFill.cpuOutline))
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: 110)
                TTTimeAxis(range: .live, end: end)
            }
            .frame(minHeight: 196)
        )
    }
}

private struct ThroughputCard: View {
    var body: some View {
        let down = ChartSeries(id: "down", label: "Download · scale 40 MB/s", color: TTColor.net,
                               points: SampleSeries.wave(base: 14e6, amplitude: 8e6, seed: 21), fillOpacity: TTChartFill.netDown)
        let up = ChartSeries(id: "up", label: "Upload · scale 4 MB/s", color: TTColor.netUp,
                             points: SampleSeries.wave(base: 1.4e6, amplitude: 0.8e6, seed: 22), fillOpacity: TTChartFill.netUp)
        return onWindow(
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Throughput") { TTLegend([down, up]) }
                TTMirroredChart(up: down, down: up, upScale: 40e6, downScale: 4e6)
                    .frame(height: 181)
                    .frame(maxHeight: .infinity)
                TTTimeAxis(range: .live, end: end)
            }
            .frame(minHeight: 268)
        )
    }
}

private struct TemperaturesCard: View {
    var body: some View {
        let p = ChartSeries(id: "p", label: "P-cores", color: TTColor.thermal,
                            points: SampleSeries.wave(base: 66, amplitude: 3, seed: 31), fillOpacity: nil, lineWidth: TTStroke.sparkHeavy)
        let g = ChartSeries(id: "g", label: "GPU", color: TTColor.thermalGPU,
                            points: SampleSeries.wave(base: 58, amplitude: 3, seed: 32), fillOpacity: nil, lineWidth: TTStroke.spark)
        let b = ChartSeries(id: "b", label: "Battery", color: TTColor.thermalBattery,
                            points: SampleSeries.wave(base: 36, amplitude: 1, seed: 33, gaps: 40..<44), fillOpacity: nil,
                            lineWidth: TTStroke.spark)
        return onWindow(
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Temperatures") { TTLegend([p, g, b]) }
                TTLineChart([p, g, b], yDomain: 40...105) { TTFormat.temperatureCompact($0, units: UnitPreferences()) }
                    .frame(height: 150)
                TTTimeAxis(range: .live, end: end).padding(.leading, 34)
            }
        )
    }
}

private struct GPUCard: View {
    var body: some View {
        let util = ChartSeries(id: "u", label: "Utilization", color: TTColor.gpu,
                               points: SampleSeries.wave(base: 0.22, amplitude: 0.1, seed: 41))
        let freq = ChartSeries(id: "f", label: "Frequency", color: TTColor.gpuAlt,
                               points: SampleSeries.wave(base: 1180, amplitude: 200, seed: 42))
        return onWindow(
            TTCard(spacing: TTSpace.x10) {
                TTCardHeader("Utilization & frequency") { TTLegend([util, freq]) }
                TTDualChart(solid: util, dashed: freq, yDomain: 0...1, dashedDomain: 0...1_578)
                    .frame(height: 160)
                TTTimeAxis(range: .live, end: end)
            }
            .frame(minHeight: 249, alignment: .top)
        )
    }
}
