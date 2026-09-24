import CoreGraphics

/// DESIGN §1.3 spacing scale + semantic aliases.
public enum TTSpace {
    public static let x1: CGFloat = 1
    public static let x2: CGFloat = 2
    public static let x3: CGFloat = 3
    public static let x4: CGFloat = 4
    public static let x5: CGFloat = 5
    public static let x6: CGFloat = 6
    public static let x7: CGFloat = 7
    public static let x8: CGFloat = 8
    public static let x9: CGFloat = 9
    public static let x10: CGFloat = 10
    public static let x12: CGFloat = 12
    public static let x14: CGFloat = 14
    public static let x16: CGFloat = 16
    public static let x18: CGFloat = 18
    public static let x20: CGFloat = 20
    public static let x21: CGFloat = 21
    public static let x24: CGFloat = 24
    public static let x32: CGFloat = 32

    public static let pagePadding: CGFloat = 20
    public static let gridGap: CGFloat = 12
    public static let cardPadding: CGFloat = 16
    public static let tileVerticalPadding: CGFloat = 14
    public static let statCellVertical: CGFloat = 12
    public static let statCellHorizontal: CGFloat = 16
    public static let tableCellGap: CGFloat = 12
    public static let tableRowInset: CGFloat = 12
    public static let legendGap: CGFloat = 14
    public static let iconTextGapCardHeader: CGFloat = 7
    public static let iconTextGapTable: CGFloat = 8
    public static let iconTextGapSidebar: CGFloat = 9
    public static let iconTextGapPopover: CGFloat = 10
}

/// DESIGN §1.3 radii.
public enum TTRadius {
    public static let r2: CGFloat = 2
    public static let r2_5: CGFloat = 2.5
    public static let r3: CGFloat = 3
    public static let r4: CGFloat = 4
    public static let r5: CGFloat = 5
    public static let r6: CGFloat = 6
    public static let r7: CGFloat = 7
    public static let r8: CGFloat = 8
    public static let r9: CGFloat = 9
    public static let card: CGFloat = 10
    public static let pill: CGFloat = 11
    public static let window: CGFloat = 12
}

/// DESIGN §1.3 strokes.
public enum TTStroke {
    public static let hairline: CGFloat = 1
    public static let icon: CGFloat = 1.5
    public static let iconFan: CGFloat = 1.4
    public static let sparkThin: CGFloat = 1.25
    public static let spark: CGFloat = 1.5
    public static let sparkHeavy: CGFloat = 1.75
    public static let cursor: CGFloat = 1.5
    public static let gauge: CGFloat = 7
    public static let glyph: CGFloat = 2.2
    public static let batteryOutline: CGFloat = 2
}

/// DESIGN §1.3 shadows (SwiftUI radius = blur / 2).
public enum TTShadow {
    public struct Spec: Sendable { public var y: CGFloat; public var radius: CGFloat; public var opacity: Double }
    public static let popover = Spec(y: 18, radius: 25, opacity: 0.60)
    public static let dialog = Spec(y: 24, radius: 30, opacity: 0.55)
}

/// DESIGN §1.3 opacity levels.
public enum TTOpacity {
    public static let disabled: Double = 0.40
    public static let pressed: Double = 0.8
    public static let cursor: Double = 0.85
}
