import AppKit
import MonitorModel
import SwiftUI

/// DESIGN §1.4 icons: 16-grid, stroke 1.5 (scaled with the drawn size), round caps/joins, no fill.
public enum TTIconName: String, CaseIterable, Sendable {
    case overview, cpu, gpu, memory, network, thermals, power, disk, processes, history
    case pause, play, settings, chevronRight, chevronDown, ellipsis, search, battery, fan, eject, quit, dragHandle

    /// SVG path data in the 16 grid (rects/circles/ellipses converted to path commands).
    var svg: String {
        switch self {
        case .overview:
            Self.rect(2.5, 2.5, 4.5, 4.5, 1) + Self.rect(9, 2.5, 4.5, 4.5, 1)
                + Self.rect(2.5, 9, 4.5, 4.5, 1) + Self.rect(9, 9, 4.5, 4.5, 1)
        case .cpu:
            Self.rect(4, 4, 8, 8, 1.5) + Self.rect(6.5, 6.5, 3, 3, 0)
                + "M6 1.5v2M10 1.5v2M6 12.5v2M10 12.5v2M1.5 6h2M1.5 10h2M12.5 6h2M12.5 10h2"
        case .gpu:
            Self.rect(1.5, 4, 13, 8, 1.5) + Self.circle(6, 8, 2) + "M10 6.5h2.5M10 9.5h2.5"
        case .memory:
            Self.rect(1.5, 4.5, 13, 6, 1) + "M4.5 10.5v2M7 10.5v2M9.5 10.5v2M12 10.5v2M4.5 7.5h1M7 7.5h1M9.5 7.5h1"
        case .network:
            "M5 13V3M5 3L2.5 5.5M5 3l2.5 2.5M11 3v10M11 13l-2.5-2.5M11 13l2.5-2.5"
        case .thermals:
            "M9.5 9.2V3a1.5 1.5 0 0 0-3 0v6.2a3 3 0 1 0 3 0zM8 7v4"
        case .power:
            "M9 1.5L3.5 9H8l-1 5.5L12.5 7H8z"
        case .disk:
            Self.ellipse(8, 4, 5.5, 2)
                + "M2.5 4v8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2V4M2.5 8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2"
        case .processes:
            "M5.5 4h8M5.5 8h8M5.5 12h8" + Self.circle(2.75, 4, 0.75) + Self.circle(2.75, 8, 0.75)
                + Self.circle(2.75, 12, 0.75)
        case .history:
            Self.circle(8, 8, 6) + "M8 4.5V8l2.5 1.5"
        case .pause:
            "M6 3.5v9M10 3.5v9"
        case .play:
            "M5 3.5v9l7-4.5z"
        case .settings:
            "M2 4.5h7M12 4.5h2M2 11.5h2M7 11.5h7" + Self.circle(10.5, 4.5, 1.5) + Self.circle(5.5, 11.5, 1.5)
        case .chevronRight:
            "M6 3.5L10.5 8 6 12.5"
        case .chevronDown:
            "M3.5 6L8 10.5 12.5 6"
        case .ellipsis:
            Self.circle(3.5, 8, 0.9) + Self.circle(8, 8, 0.9) + Self.circle(12.5, 8, 0.9)
        case .search:
            Self.circle(7, 7, 4.5) + "M10.5 10.5L14 14"
        case .battery:
            Self.rect(1.5, 4.5, 11.5, 7, 1.5) + "M14.5 7v2"
        case .fan:
            Self.circle(8, 8, 1.5)
                + "M8 6.5C8 3 10.5 2 12 3.5M9.5 8c3.5 0 4.5 2.5 3 4M8 9.5c0 3.5-2.5 4.5-4 3M6.5 8C3 8 2 5.5 3.5 4"
        case .eject:
            "M8 3L3 9h10zM3 12.5h10"
        case .quit:
            "M8 2v5.5M4.4 4.2a5 5 0 1 0 7.2 0"
        case .dragHandle:
            "M4 5.5h8M4 8h8M4 10.5h8"
        }
    }

    /// Default tint (§1.4 color column).
    public var defaultColor: Color {
        switch self {
        case .cpu: TTColor.cpu
        case .gpu: TTColor.gpu
        case .memory: TTColor.mem
        case .network: TTColor.net
        case .thermals: TTColor.thermal
        case .power: TTColor.power
        case .disk: TTColor.disk
        case .battery: TTColor.battery
        case .fan: TTColor.thermal
        case .chevronRight, .chevronDown, .dragHandle: TTColor.textTertiary
        default: TTColor.textSecondary
        }
    }

    public static func category(_ c: MonitorModel.Category) -> TTIconName {
        switch c {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .thermals: .thermals
        case .power: .power
        case .disk: .disk
        }
    }

    public static func page(_ p: DashboardPage) -> TTIconName {
        switch p {
        case .overview: .overview
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .thermals: .thermals
        case .power: .power
        case .disk: .disk
        case .processes: .processes
        case .history: .history
        }
    }

    // SVG primitives → path data.
    private static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> String {
        if r == 0 { return "M\(x) \(y)h\(w)v\(h)h\(-w)z" }
        return "M\(x + r) \(y)H\(x + w - r)A\(r) \(r) 0 0 1 \(x + w) \(y + r)V\(y + h - r)A\(r) \(r) 0 0 1 \(x + w - r) \(y + h)"
            + "H\(x + r)A\(r) \(r) 0 0 1 \(x) \(y + h - r)V\(y + r)A\(r) \(r) 0 0 1 \(x + r) \(y)z"
    }

    private static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> String { ellipse(cx, cy, r, r) }

    private static func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> String {
        "M\(cx - rx) \(cy)A\(rx) \(ry) 0 1 0 \(cx + rx) \(cy)A\(rx) \(ry) 0 1 0 \(cx - rx) \(cy)z"
    }
}

/// Parsed icon paths, built once.
enum TTIconPaths {
    static let all: [TTIconName: Path] = Dictionary(
        uniqueKeysWithValues: TTIconName.allCases.map { ($0, SVGPath.parse($0.svg)) }
    )
}

/// Icon shape in a square frame; the 16-grid path is scaled to the frame.
public struct TTIconShape: Shape {
    public var name: TTIconName

    public init(_ name: TTIconName) { self.name = name }

    public func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 16
        let path = TTIconPaths.all[name] ?? Path()
        return path.applying(CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: rect.minX, ty: rect.minY))
    }
}

/// Rasterized template `NSImage`s of the icons, for places that only accept images (macOS `Menu` labels keep only
/// Image/Text). Drawn at @2x, black on clear, `isTemplate` so the menu tints them; cached per (name, size).
@MainActor public enum TTIconImage {
    private static var cache: [String: NSImage] = [:]

    public static func template(_ name: TTIconName, size: CGFloat = 16, gridStroke: CGFloat = TTStroke.icon) -> NSImage {
        make(name, size: size, gridStroke: gridStroke, hex: nil)
    }

    /// Pre-colored (non-template) image: menu buttons draw it as is, independent of their tint handling.
    public static func colored(_ name: TTIconName, hex: UInt32, size: CGFloat = 16, gridStroke: CGFloat = TTStroke.icon) -> NSImage {
        make(name, size: size, gridStroke: gridStroke, hex: hex)
    }

    private static func make(_ name: TTIconName, size: CGFloat, gridStroke: CGFloat, hex: UInt32?) -> NSImage {
        let key = "\(name.rawValue)@\(size)/\(gridStroke)/\(hex.map { String($0) } ?? "t")"
        if let hit = cache[key] { return hit }
        let path = TTIconShape(name).path(in: CGRect(x: 0, y: 0, width: size, height: size))
        let lineWidth = gridStroke * size / 16
        let color = hex.map { NSColor(hex: $0) } ?? .black
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path.cgPath)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            return true
        }
        image.isTemplate = hex == nil
        cache[key] = image
        return image
    }
}

/// An icon at `size` pt, stroke 1.5 in the 16 grid (so 1.5·size/16 pt), round caps and joins.
public struct TTIcon: View, Equatable {
    public var name: TTIconName
    public var size: CGFloat
    public var color: Color?
    public var gridStroke: CGFloat

    public init(_ name: TTIconName, size: CGFloat = 16, color: Color? = nil, gridStroke: CGFloat = TTStroke.icon) {
        self.name = name
        self.size = size
        self.color = color
        self.gridStroke = gridStroke
    }

    public var body: some View {
        TTIconShape(name)
            .stroke(color ?? name.defaultColor,
                    style: StrokeStyle(lineWidth: gridStroke * size / 16, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
