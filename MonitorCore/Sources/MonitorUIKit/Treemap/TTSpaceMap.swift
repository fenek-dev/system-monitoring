import SwiftUI

/// One input tile of `TTSpaceMap`. Generic on purpose: no storage-model types.
public struct TTSpaceMapTile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case normal
        /// The merged tail ("N smaller items"); produced by `TTSpaceMapLayout`, not meant as input.
        case smaller
        /// Unreadable: hatched, no size, not drillable.
        case restricted
    }

    public var id: Int32
    public var value: Double
    public var label: String
    public var valueText: String
    public var kind: Kind
    /// Fraction 0...1 shown in the tooltip / accessibility label instead of `value / total`. For callers whose
    /// layout weights include nominal entries (restricted tiles) that must not dilute the real shares.
    public var share: Double?

    public init(id: Int32, value: Double, label: String, valueText: String, kind: Kind = .normal, share: Double? = nil) {
        self.id = id
        self.value = value
        self.label = label
        self.valueText = valueText
        self.kind = kind
        self.share = share
    }
}

/// Cut + cap + squarify for `TTSpaceMap` (DESIGN §2.28 Space Map variant). Public so the page's children table can
/// show exactly the set the map shows (`shown`, `smallerCount`, `smallerValue`).
/// Tiles must be presorted by `value` descending. A tail is merged into one "N smaller items" tile, laid out last:
/// - from the first tile under 0.5 % of the total (binary search),
/// - or from the first tile whose laid-out rect is under 24×16 pt (re-laid-out until stable, since merging grows
///   the smaller tile),
/// - and never more than 200 tiles are kept.
/// Restricted tiles are laid out by their `value`: the caller supplies a nominal weight, as they have no size.
public struct TTSpaceMapLayout: Equatable, Sendable {
    public struct Placed: Equatable, Sendable {
        public let tile: TTSpaceMapTile
        /// Laid-out rect without gutter (the view insets each tile by 1 pt).
        public let rect: CGRect
    }

    public static let maxTiles = 200
    public static let minShare = 0.005
    public static let minTileSize = CGSize(width: 24, height: 16)
    /// Id of the merged tile; callers treat it as non-drillable.
    public static let smallerID = Int32.min

    /// Visible tiles in order, the "smaller" tile last.
    public let placed: [Placed]
    /// The kept input tiles (without the merged one).
    public let shown: [TTSpaceMapTile]
    public let smallerCount: Int
    public let smallerValue: Double
    /// Sum of all positive input values (the denominator for shares).
    public let total: Double

    public static func make(_ tiles: [TTSpaceMapTile], in size: CGSize) -> TTSpaceMapLayout {
        func valid(_ v: Double) -> Bool { v.isFinite && v > 0 }
        let total = tiles.reduce(0) { valid($1.value) ? $0 + $1.value : $0 }
        guard total > 0 else {
            return TTSpaceMapLayout(placed: [], shown: [], smallerCount: tiles.count, smallerValue: 0, total: 0)
        }

        // Presorted: the first tile under the threshold starts the tail.
        let threshold = minShare * total
        var lo = 0, hi = tiles.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if tiles[mid].value < threshold || !valid(tiles[mid].value) { hi = mid } else { lo = mid + 1 }
        }
        var keep = min(lo, maxTiles)
        var tailValue = 0.0
        for t in tiles[keep...] where valid(t.value) { tailValue += t.value }

        let rect = CGRect(origin: .zero, size: size)
        guard rect.width > 0, rect.height > 0 else {
            return TTSpaceMapLayout(placed: [], shown: Array(tiles[..<keep]), smallerCount: tiles.count - keep,
                                    smallerValue: tailValue, total: total)
        }
        while true {
            let hasTail = keep < tiles.count
            var values = tiles[..<keep].map(\.value)
            if hasTail { values.append(tailValue) }
            let rects = TreemapLayout.squarify(presorted: values, otherIndex: hasTail ? keep : nil, in: rect)
            if let cut = (0..<keep).first(where: { rects[$0].width < minTileSize.width || rects[$0].height < minTileSize.height }) {
                for t in tiles[cut..<keep] where valid(t.value) { tailValue += t.value }
                keep = cut
                continue
            }
            var placed = (0..<keep).map { Placed(tile: tiles[$0], rect: rects[$0]) }
            let count = tiles.count - keep
            if hasTail {
                let smaller = TTSpaceMapTile(id: smallerID, value: tailValue,
                                             label: "\(TTFormat.count(count)) smaller item\(count == 1 ? "" : "s")",
                                             valueText: "", kind: .smaller)
                placed.append(Placed(tile: smaller, rect: rects[keep]))
            }
            return TTSpaceMapLayout(placed: placed, shown: Array(tiles[..<keep]), smallerCount: count,
                                    smallerValue: tailValue, total: total)
        }
    }
}

/// DESIGN §2.28 Space Map variant (§3.17 Storage): a squarified map of one directory's children.
/// - The whole map is one `Canvas` (fill `disk` @ 0.28; labels only where they fit, as `TTTreemap`); layout is cached
///   per (tiles, size) and does not animate on drill-down.
/// - Hover highlight (@ 0.45), the tooltip and click live in a separate overlay layer: moving the pointer redraws
///   only that layer, never the map.
/// - "Smaller items" and restricted tiles are `fillTrack` (restricted with a diagonal hatch, size "—", tooltip
///   "Needs Full Disk Access") and never call `onDrill`.
public struct TTSpaceMap: View {
    let tiles: [TTSpaceMapTile]
    let hoveredID: Binding<Int32?>
    let formatValue: (Double) -> String
    let onDrill: (Int32) -> Void
    @State private var cache = LayoutCache()

    /// `tiles` must be presorted by value descending. `formatValue` renders the summed size of the "smaller items" tile.
    public init(_ tiles: [TTSpaceMapTile], hoveredID: Binding<Int32?>,
                formatValue: @escaping (Double) -> String = { TTFormat.bytes(UInt64(max(0, $0))) },
                onDrill: @escaping (Int32) -> Void) {
        self.tiles = tiles
        self.hoveredID = hoveredID
        self.formatValue = formatValue
        self.onDrill = onDrill
    }

    public var body: some View {
        GeometryReader { geo in
            let resolved = cache.resolve(tiles, size: geo.size)
            ZStack {
                MapCanvas(resolved: resolved, formatValue: formatValue)
                HoverLayer(resolved: resolved, hoveredID: hoveredID, formatValue: formatValue, onDrill: onDrill)
            }
            .accessibilityElement(children: .contain)
            .accessibilityChildren {
                VStack {
                    ForEach(resolved.layout.placed, id: \.tile.id) { p in
                        Button(resolved.accessibilityLabel(p.tile, formatValue: formatValue)) {
                            if p.tile.kind == .normal { onDrill(p.tile.id) }
                        }
                    }
                }
            }
        }
    }

    /// Layout + the derived data both layers share, computed once per (tiles, size).
    struct Resolved {
        let layout: TTSpaceMapLayout
        let hit: SpaceMapHitTest
        let indexByID: [Int32: Int]
        /// Hatch strokes per placed index (restricted tiles only), built with the layout so redraws only replay them.
        let hatch: [Int: Path]

        func accessibilityLabel(_ t: TTSpaceMapTile, formatValue: (Double) -> String) -> String {
            switch t.kind {
            case .restricted: "\(t.label), needs Full Disk Access"
            default: "\(t.label), \(valueText(t, formatValue: formatValue)), \(share(t))%"
            }
        }

        func valueText(_ t: TTSpaceMapTile, formatValue: (Double) -> String) -> String {
            t.kind == .smaller ? formatValue(t.value) : t.valueText
        }

        func share(_ t: TTSpaceMapTile) -> String { TTFormat.number((t.share ?? t.value / layout.total) * 100, digits: 0) }

        func tooltip(_ t: TTSpaceMapTile, formatValue: (Double) -> String) -> String {
            switch t.kind {
            case .restricted: "Needs Full Disk Access"
            case .smaller: "\(t.label) · \(formatValue(t.value))"
            case .normal: "\(t.label) · \(t.valueText) · \(share(t))%"
            }
        }
    }

    /// Reference type so `body` can memoize without a state write; only read on the main actor.
    final class LayoutCache {
        private var key: (tiles: [TTSpaceMapTile], size: CGSize)?
        private var value: Resolved?

        func resolve(_ tiles: [TTSpaceMapTile], size: CGSize) -> Resolved {
            // Array equality short-circuits on identical buffers, so an unchanged input costs O(1).
            if let key, let value, key.size == size, key.tiles == tiles { return value }
            let layout = TTSpaceMapLayout.make(tiles, in: size)
            var hatch: [Int: Path] = [:]
            for (i, p) in layout.placed.enumerated() where p.tile.kind == .restricted {
                hatch[i] = Self.hatchPath(in: p.rect.insetBy(dx: 1, dy: 1))
            }
            let resolved = Resolved(
                layout: layout,
                hit: SpaceMapHitTest(layout.placed.map { (id: $0.tile.id, rect: $0.rect) }),
                indexByID: Dictionary(layout.placed.enumerated().map { ($1.tile.id, $0) }, uniquingKeysWith: { a, _ in a }),
                hatch: hatch)
            key = (tiles, size)
            value = resolved
            return resolved
        }

        static func hatchPath(in r: CGRect) -> Path {
            var path = Path()
            guard r.width > 0, r.height > 0 else { return path }
            var x = r.minX - r.height
            while x < r.maxX {
                path.move(to: CGPoint(x: x, y: r.maxY))
                path.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                x += 6
            }
            return path
        }
    }

    private static func shape(_ r: CGRect) -> Path {
        Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: TTRadius.r4, style: .continuous)
    }

    private struct MapCanvas: View {
        let resolved: Resolved
        let formatValue: (Double) -> String

        var body: some View {
            let labels = labels
            Canvas(rendersAsynchronously: false) { ctx, _ in
                for (i, p) in resolved.layout.placed.enumerated() {
                    let r = p.rect.insetBy(dx: 1, dy: 1)
                    guard r.width > 0, r.height > 0 else { continue }
                    let shape = TTSpaceMap.shape(p.rect)
                    switch p.tile.kind {
                    case .normal:
                        ctx.fill(shape, with: .color(TTColor.disk.opacity(0.28)))
                    case .smaller:
                        ctx.fill(shape, with: .color(TTColor.fillTrack))
                    case .restricted:
                        ctx.fill(shape, with: .color(TTColor.fillTrack))
                        if let hatch = resolved.hatch[i] {
                            ctx.drawLayer { layer in
                                layer.clip(to: shape)
                                layer.stroke(hatch, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
                            }
                        }
                    }
                }
                for l in labels {
                    if let symbol = ctx.resolveSymbol(id: l.key) { ctx.draw(symbol, at: l.origin, anchor: .topLeading) }
                }
            } symbols: {
                // Symbols (not `ctx.draw(Text)`) so long names truncate with an ellipsis instead of overflowing.
                ForEach(labels, id: \.key) { l in
                    Text(l.text).font(l.font).foregroundStyle(l.color).lineLimit(1).truncationMode(.tail)
                        .frame(width: l.width, alignment: .leading).tag(l.key)
                }
            }
        }

        struct Label {
            let key: Int
            let text: String
            let font: Font
            let color: Color
            let origin: CGPoint
            let width: CGFloat
        }

        /// Name (and value line) per tile, only where `TTTreemap`'s thresholds say they fit.
        var labels: [Label] {
            var out: [Label] = []
            for (i, p) in resolved.layout.placed.enumerated() {
                let r = p.rect.insetBy(dx: 1, dy: 1)
                guard TTTreemap.showsName(r.size) else { continue }
                let inner = r.insetBy(dx: 8, dy: 8)
                guard inner.width > 0 else { continue }
                let isNormal = p.tile.kind == .normal
                out.append(Label(key: i * 2, text: p.tile.label, font: isNormal ? TTFont.body12Strong : TTFont.caption,
                                 color: isNormal ? TTColor.textPrimary : TTColor.textSecondary,
                                 origin: inner.origin, width: inner.width))
                guard TTTreemap.showsValue(r.size) else { continue }
                let value = p.tile.kind == .restricted ? "—" : resolved.valueText(p.tile, formatValue: formatValue)
                out.append(Label(key: i * 2 + 1, text: value, font: TTFont.caption, color: TTColor.textSecondary,
                                 origin: CGPoint(x: inner.minX, y: inner.minY + 18), width: inner.width))
            }
            return out
        }
    }

    /// Reads `hoveredID`; the only layer that re-evaluates on pointer movement.
    private struct HoverLayer: View {
        let resolved: Resolved
        let hoveredID: Binding<Int32?>
        let formatValue: (Double) -> String
        let onDrill: (Int32) -> Void

        var body: some View {
            let hovered = hoveredID.wrappedValue.flatMap { resolved.indexByID[$0] }.map { resolved.layout.placed[$0] }
            Canvas(rendersAsynchronously: false) { ctx, _ in
                // Alpha chosen so 0.28 base + overlay composites to the 0.45 hover opacity: 1 - 0.72·(1 - a) = 0.45.
                if let hovered, hovered.tile.kind == .normal {
                    ctx.fill(TTSpaceMap.shape(hovered.rect), with: .color(TTColor.disk.opacity(1 - 0.55 / 0.72)))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                let next: Int32?
                switch phase {
                case .active(let p): next = resolved.hit.tile(at: p)
                case .ended: next = nil
                }
                if hoveredID.wrappedValue != next { hoveredID.wrappedValue = next }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                if let id = resolved.hit.tile(at: tap.location), id != TTSpaceMapLayout.smallerID,
                   let i = resolved.indexByID[id], resolved.layout.placed[i].tile.kind == .normal {
                    onDrill(id)
                }
            })
            .help(hovered.map { resolved.tooltip($0.tile, formatValue: formatValue) } ?? "")
        }
    }
}
