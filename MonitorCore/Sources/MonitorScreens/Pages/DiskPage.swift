import Foundation
import MonitorLive
import MonitorModel
import MonitorUIKit
import SwiftUI

/// DESIGN §3.11 Disk: stat strip (4) · Volumes · Throughput (span 2) + SSD health · Disk activity by process (flex).
/// SMART/volumes are sampled only while this page is visible (`UIVisibility.demand` → `.smart` + `.volumes`).
public struct DiskPage: View {
    @Environment(LiveModel.self) private var live

    public init() {}

    public var body: some View {
        DiskPageColumn {
            DiskStatStrip()
            VolumesCard()
            DiskGrid3Row(minHeight: 247) {
                ThroughputCard()
                SSDHealthCard()
            }
            DiskActivityCard()
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .pageHeader(subtitle: DiskCopy.subtitle(live.disk.smart))
    }
}

// MARK: - Copy

enum DiskCopy {
    static let smartUnavailable = "SMART data unavailable without root"

    /// "Apple SSD · 1 TB · PCIe" (NVMe controller model, capacity, transport). PCIe is stated only when NVMe
    /// SMART data was read (the NVMe log exists only on PCIe/NVMe controllers).
    static func subtitle(_ smart: SMARTInfo?) -> String? {
        guard let smart else { return nil }
        var parts: [String] = []
        if let model = smart.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty {
            parts.append(model.uppercased().hasPrefix("APPLE SSD") ? "Apple SSD" : model)
        }
        if let cap = smart.capacityBytes { parts.append(TTFormat.storage(cap, style: .capacity)) }
        if smart.percentageUsed != nil || smart.dataWrittenBytes != nil { parts.append("PCIe") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Internal · APFS · encrypted".
    static func volumeDetail(_ v: VolumeInfo) -> String {
        [v.busLabel ?? (v.isInternal ? "Internal" : "External"), v.fsType, v.isEncrypted ? "encrypted" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Used (incl. purgeable) = total − available; "612 GB of 994 GB".
    static func usedBytes(_ v: VolumeInfo) -> UInt64 { v.totalBytes > v.availableBytes ? v.totalBytes - v.availableBytes : 0 }

    static func usage(_ v: VolumeInfo) -> String {
        "\(TTFormat.storage(usedBytes(v), style: .capacity)) of \(TTFormat.storage(v.totalBytes, style: .capacity))"
    }

    /// Volume bar: used (without purgeable), then purgeable, as fractions of the total.
    static func segments(_ v: VolumeInfo) -> (used: Double, purgeable: Double) {
        guard v.totalBytes > 0 else { return (0, 0) }
        let total = Double(v.totalBytes)
        let used = Double(usedBytes(v))
        let purge = min(Double(v.purgeableBytes ?? 0), used)
        return ((used - purge) / total, purge / total)
    }

    /// Boot volume first, then by name.
    static func ordered(_ volumes: [VolumeInfo], boot: VolumeInfo?) -> [VolumeInfo] {
        volumes.sorted { a, b in
            if a.id == boot?.id { return b.id != boot?.id }
            if b.id == boot?.id { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    enum Health: Equatable { case healthy, worn, failing }

    /// Badge: Failing (critical warning ≠ 0 or failing status), Worn (≥ 80 % used or warning status), Healthy.
    static func health(_ s: SMARTInfo) -> Health? {
        if (s.criticalWarning ?? 0) != 0 || s.status == .failing { return .failing }
        if (s.percentageUsed ?? 0) >= 80 || s.status == .warning { return .worn }
        if s.status == .healthy || s.percentageUsed != nil { return .healthy }
        return nil
    }

    /// Status-only when the NVMe SMART log could not be read (DiskArbitration/IOKit `SMART Status` only).
    static func isStatusOnly(_ s: SMARTInfo) -> Bool {
        s.percentageUsed == nil && s.dataWrittenBytes == nil && s.dataReadBytes == nil && s.temperatureC == nil
            && s.powerOnHours == nil && s.unsafeShutdowns == nil
    }

    static func statusText(_ s: SMARTStatus) -> String? {
        switch s {
        case .healthy: "Verified"
        case .warning: "Warning"
        case .failing: "Failing"
        case .unknown: nil
        }
    }

    static func wear(_ pct: Double?) -> String? { pct.map { "\(TTFormat.percent($0 / 100)) used" } }
}

// MARK: - Layout helpers

private struct DiskPageColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: TTSpace.gridGap) { content }
            .padding(TTSpace.pagePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TTColor.bgWindow)
    }
}

/// `grid3` row of span 2 + 1, stretched to the tallest cell (at least `minHeight`).
private struct DiskGrid3Row: Layout {
    let minHeight: CGFloat

    static func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let col = max(0, total - 2 * TTSpace.gridGap) / 3
        return (2 * col + TTSpace.gridGap, col)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 1020
        let (a, b) = Self.widths(total)
        var h = minHeight
        for (i, s) in subviews.prefix(2).enumerated() {
            h = max(h, s.sizeThatFits(ProposedViewSize(width: i == 0 ? a : b, height: nil)).height)
        }
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (a, b) = Self.widths(bounds.width)
        for (i, s) in subviews.prefix(2).enumerated() {
            s.place(at: CGPoint(x: i == 0 ? bounds.minX : bounds.minX + a + TTSpace.gridGap, y: bounds.minY),
                    anchor: .topLeading, proposal: ProposedViewSize(width: i == 0 ? a : b, height: bounds.height))
        }
    }
}

// MARK: - Stat strip

private struct DiskStatStrip: View {
    @Environment(LiveModel.self) private var live

    var body: some View {
        let d = live.disk
        let h = live.sensorHealth
        let boot = d.bootVolume
        TTStatStrip([
            .init(id: "read", label: "Read", value: d.readBps.map { TTFormat.diskRate($0) },
                  detail: d.readIOPS.map { "\(TTFormat.iops($0)) IOPS" } ?? "\u{00A0}", tint: TTColor.disk,
                  unavailableReason: unavailableReason(.diskRead, health: h)),
            .init(id: "write", label: "Write", value: d.writeBps.map { TTFormat.diskRate($0) },
                  detail: d.writeIOPS.map { "\(TTFormat.iops($0)) IOPS" },
                  unavailableReason: unavailableReason(.diskWrite, health: h)),
            .init(id: "free", label: "Free space", value: boot.map { TTFormat.storage($0.availableBytes, style: .capacity) },
                  detail: boot.map { "on \($0.name)" },
                  unavailableReason: live.status(of: .volumes).reason ?? "Boot volume not found"),
            .init(id: "wear", label: "SSD wear", value: DiskCopy.wear(d.smart?.percentageUsed),
                  detail: d.smart?.dataWrittenBytes.map { "\(TTFormat.storage($0, style: .lifetime)) written" },
                  unavailableReason: DiskCopy.smartUnavailable),
        ])
    }
}

// MARK: - Volumes

private struct VolumesCard: View {
    @Environment(LiveModel.self) private var live

    private static let columns = [GridItem(.flexible(), spacing: TTSpace.x32, alignment: .top),
                                  GridItem(.flexible(), spacing: TTSpace.x32, alignment: .top)]

    var body: some View {
        let d = live.disk
        let volumes = DiskCopy.ordered(d.volumes, boot: d.bootVolume)
        TTCard(spacing: TTSpace.x12) {
            TTCardHeader("Volumes")
            if volumes.isEmpty {
                TTEmptyState(.unavailable(live.status(of: .volumes).reason ?? "No volumes mounted"))
                    .frame(height: 44)
            } else {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: TTSpace.x12) {
                    ForEach(volumes) { VolumeView(volume: $0) }
                }
            }
            TTLegend(items: [("Used", TTColor.disk), ("Purgeable", TTColor.diskPurgeable)])
        }
    }
}

private struct VolumeView: View {
    let volume: VolumeInfo
    @Environment(\.processActions) private var actions

    var body: some View {
        let seg = DiskCopy.segments(volume)
        VStack(alignment: .leading, spacing: TTSpace.x8) {
            HStack(spacing: TTSpace.x10) {
                TTIcon(.disk, size: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(volume.name).font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary).lineLimit(1)
                    Text(DiskCopy.volumeDetail(volume)).font(TTFont.caption).foregroundStyle(TTColor.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(DiskCopy.usage(volume)).font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                    .monospacedDigit().lineLimit(1)
                if volume.isEjectable {
                    TTIconButton(.eject, label: "Eject \(volume.name)", variant: .filled) {
                        let v = volume, actions = actions
                        Task { @MainActor in _ = await actions.eject(v) }
                    }
                }
            }
            TTSegmentBar([.init(seg.used, TTColor.disk), .init(seg.purgeable, TTColor.diskPurgeable)], style: .volume)
        }
    }
}

// MARK: - Throughput

private struct ThroughputCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(NavigationModel.self) private var nav
    @Environment(\.now) private var fixedNow
    @Environment(\.historyProvider) private var history
    @State private var stored: [HistoryMetric: [SeriesPoint]] = [:]
    /// Live ceiling only grows during a session; re-evaluated on range change (DESIGN §5.10).
    @State private var ceiling: Double = 0

    var body: some View {
        let range = nav.range
        let end = fixedNow ?? live.lastUpdate ?? Date()
        let read = points(.diskRead, range)
        let write = points(.diskWrite, range)
        let windowMax = (read + write).compactMap(\.value).max() ?? 0
        let scale = max(ceiling, TTFormat.niceRateCeiling(windowMax))
        let reason = unavailableReason(.diskRead, health: live.sensorHealth)
        let empty = ChartSegments.sampleCount(read) < 2 && ChartSegments.sampleCount(write) < 2
        TTCard(spacing: TTSpace.x10) {
            TTCardHeader("Throughput") {
                TTLegend(items: [("Read", TTColor.disk), ("Write", TTColor.diskWrite),
                                 ("scale \(TTFormat.rateScale(scale, units: UnitPreferences()))", .clear)])
            }
            Group {
                if let reason, empty {
                    TTEmptyState(.unavailable(reason))
                } else {
                    TTMirroredChart(
                        up: ChartSeries(id: "read", label: "Read", color: TTColor.disk, points: read,
                                        fillOpacity: TTChartFill.diskRead),
                        down: ChartSeries(id: "write", label: "Write", color: TTColor.diskWrite, points: write,
                                          fillOpacity: TTChartFill.diskWrite),
                        upScale: scale, downScale: scale)
                }
            }
            .frame(minHeight: 161, maxHeight: .infinity)
            TTTimeAxis(range: range, end: end)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: scale) { _, new in if new > ceiling { ceiling = new } }
        .onChange(of: range) { ceiling = 0 }
        .task(id: DiskRangeKey(range: range, end: end)) {
            guard range != .live else {
                if !stored.isEmpty { stored = [:] }
                return
            }
            let result = try? await history.series([.diskRead, .diskWrite], range: range, end: end, bucket: nil)
            if !Task.isCancelled { stored = result ?? [:] }
        }
    }

    private func points(_ metric: HistoryMetric, _ range: HistoryRange) -> [SeriesPoint] {
        range == .live ? live.series(metric) : (stored[metric] ?? [])
    }
}

private struct DiskRangeKey: Hashable {
    let range: HistoryRange
    let slot: Int

    init(range: HistoryRange, end: Date) {
        self.range = range
        let bucket = Double(range.displayBucket.components.seconds)
        slot = range == .live ? 0 : Int(end.timeIntervalSince1970 / max(bucket, 1))
    }
}

// MARK: - SSD health

private struct SSDHealthCard: View {
    @Environment(LiveModel.self) private var live
    @Environment(\.unitPreferences) private var units

    var body: some View {
        let smart = live.disk.smart
        TTCard(spacing: TTSpace.x6) {
            TTCardHeader("SSD health") {
                if let s = smart, let h = DiskCopy.health(s) {
                    switch h {
                    case .healthy: TTBadge("Healthy", level: .calm)
                    case .worn: TTBadge("Worn", level: .elevated)
                    case .failing: TTBadge("Failing", level: .critical)
                    }
                }
            }
            if let s = smart {
                if DiskCopy.isStatusOnly(s) {
                    TTKeyValueList(rows: [.init("Status", DiskCopy.statusText(s.status),
                                                unavailableReason: DiskCopy.smartUnavailable)])
                } else {
                    TTKeyValueList(rows: [
                        .init("Percentage used", s.percentageUsed.map { TTFormat.percent($0 / 100) },
                              unavailableReason: DiskCopy.smartUnavailable),
                        .init("Data written", s.dataWrittenBytes.map { TTFormat.storage($0, style: .lifetime) },
                              unavailableReason: DiskCopy.smartUnavailable),
                        .init("Data read", s.dataReadBytes.map { TTFormat.storage($0, style: .lifetime) },
                              unavailableReason: DiskCopy.smartUnavailable),
                        .init("Temperature", s.temperatureC.map { TTFormat.temperature($0, units: units) },
                              unavailableReason: DiskCopy.smartUnavailable),
                        .init("Power-on hours", s.powerOnHours.map { TTFormat.count($0) },
                              unavailableReason: DiskCopy.smartUnavailable),
                        .init("Unsafe shutdowns", s.unsafeShutdowns.map { TTFormat.count($0) },
                              unavailableReason: DiskCopy.smartUnavailable),
                    ])
                }
                Spacer(minLength: 0)
            } else {
                TTEmptyState(.unavailable(live.status(of: .smart).reason ?? DiskCopy.smartUnavailable))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Disk activity by process

struct DiskRow: Identifiable, Equatable {
    var id: String
    var name: String
    var identity: AppIdentity?
    var read: Double?
    var write: Double?
    var readTotal: UInt64?
    var writeTotal: UInt64?
    var target: ProcessTarget

    var rate: Double { (read ?? 0) + (write ?? 0) }
}

enum DiskRows {
    /// Processes with disk I/O this tick (restricted pids are counted in their coalition rows).
    static func rows(_ processes: [ProcessSample], identity: (AppKey) -> AppIdentity?) -> [DiskRow] {
        processes.compactMap { p in
            guard (p.diskReadBps ?? 0) + (p.diskWriteBps ?? 0) > 0 else { return nil }
            return DiskRow(id: "pid:\(p.id.pid):\(p.id.startTimeUs)", name: p.name, identity: identity(p.app),
                           read: p.diskReadBps, write: p.diskWriteBps, readTotal: p.diskReadTotal,
                           writeTotal: p.diskWriteTotal,
                           target: .process(pid: p.pid, name: p.name, path: p.path, uid: p.uid))
        }
    }
}

private struct DiskActivityCard: View {
    @Environment(LiveModel.self) private var live
    @State private var selection: String?

    var body: some View {
        let rows = DiskRows.rows(live.processes) { live.app($0)?.identity }
        TTCard(spacing: TTSpace.x8) {
            TTCardHeader("Disk activity by process")
            TTTable(rows: rows, columns: Self.columns, selection: $selection,
                    sort: .constant((column: "read", descending: true)),
                    rowMenu: { AnyView(TTRowActionsMenu(target: $0.target)) },
                    style: TTTableStyle(rowHeight: 32, emptyMessage: "No disk activity"))
                .clipped()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// DESIGN §3.11 template `minmax(0,2fr) 100 100 110 120 28`; fixed-sorted by read + write.
    static let columns: [TTTable<DiskRow>.Column] = [
        .init(id: "name", title: "Process", width: .fraction(2, min: 0)) { row in
            AnyView(TTNameCell(identity: row.identity, name: row.name))
        },
        .init(id: "read", title: "Read", width: .fixed(100), alignment: .trailing, sortKey: { $0.rate }) { row in
            AnyView(MetricValue(TTFormat.diskRateCell(row.read), font: TTFont.body12))
        },
        .init(id: "write", title: "Write", width: .fixed(100), alignment: .trailing) { row in
            AnyView(MetricValue(TTFormat.diskRateCell(row.write), font: TTFont.body12))
        },
        .init(id: "readSession", title: "Read (session)", width: .fixed(110), alignment: .trailing) { row in
            AnyView(MetricValue(row.readTotal.map { TTFormat.storage($0, style: .detail) },
                                unavailableReason: "Not reported for this process", font: TTFont.body12))
        },
        .init(id: "writeSession", title: "Written (session)", width: .fixed(120), alignment: .trailing) { row in
            AnyView(MetricValue(row.writeTotal.map { TTFormat.storage($0, style: .detail) },
                                unavailableReason: "Not reported for this process", font: TTFont.body12))
        },
        .init(id: "actions", title: "", width: .fixed(28), alignment: .trailing) { row in
            AnyView(TTRowActionsButton(target: row.target, name: row.name))
        },
    ]
}
