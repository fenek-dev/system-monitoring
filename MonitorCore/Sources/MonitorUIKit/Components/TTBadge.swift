import MonitorModel
import SwiftUI

/// DESIGN §2.15 pill badge: height 22, padding 8, radius 11, `fillTrack`; HStack gap 6 of a 7×7 dot and
/// `captionMedium` `textPrimary`. `level` colors the dot with the status color; `dot` sets any color
/// (e.g. the category accent for "8 cores"); neither → no dot.
public struct TTBadge: View, Equatable {
    let text: String
    let dot: Color?

    public init(_ text: String, level: AlertLevel? = nil) {
        self.text = text
        dot = level.map(TTColor.level)
    }

    public init(_ text: String, dot: Color?) {
        self.text = text
        self.dot = dot
    }

    public var body: some View {
        HStack(spacing: TTSpace.x6) {
            if let dot { TTDot(color: dot) }
            Text(text)
                .font(TTFont.captionMedium)
                .foregroundStyle(TTColor.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, TTSpace.x8)
        .frame(height: 22)
        .background(Capsule().fill(TTColor.fillTrack))
        .fixedSize()
    }
}

/// 7×7 status dot (DESIGN §1.3 "Dots").
public struct TTDot: View, Equatable {
    let color: Color
    let size: CGFloat
    public init(color: Color, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }
    public var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}
