import AppKit
import MonitorModel
import SwiftUI

/// StatusIcon@2x artboard (640×330): three state cards with the 72-pt glyph (SwiftUI) and a fake menu bar strip
/// with the 18-pt `StatusGlyphRenderer` image (viewBox · 8/9 ≙ the design's 16-pt SVG).
@MainActor enum GalleryGlyph {
    static var items: [TTGallery.Item] {
        [.init(id: "status-icons", size: CGSize(width: 640, height: 330)) { AnyView(StatusIconsArtboard()) }]
    }

    static let states: [(String, AlertState, String)] = [
        ("Calm", .calm, "Monochrome, follows the menu bar tint. Five arcs: CPU, GPU, memory, network, thermals."),
        ("Elevated", AlertState(level: .elevated, arcs: arcs(.thermals, .elevated)),
         "The stressed category’s arc and the center turn amber. Here, thermals is at Fair."),
        ("Critical", AlertState(level: .critical, arcs: arcs(.thermals, .critical)),
         "Arc and center turn red and the icon pulses once. It stays red until the stress clears."),
    ]

    static func arcs(_ arc: IconArc, _ level: AlertLevel) -> [IconArc: AlertLevel] {
        var a = Dictionary(uniqueKeysWithValues: IconArc.allCases.map { ($0, AlertLevel.calm) })
        a[arc] = level
        return a
    }
}

private struct StatusIconsArtboard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(GalleryGlyph.states.indices, id: \.self) { i in
                let (title, state, text) = GalleryGlyph.states[i]
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: 0x1D1E22))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(TTColor.borderCard))
                        .overlay(TTStatusGlyph(state: state, size: 72, template: false))
                        .frame(height: 122) // CSS content-box: 120 + 1-pt border each side
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        Image(nsImage: StatusGlyphRenderer.image(for: state))
                            .renderingMode(state.level == .calm ? .template : .original)
                            .foregroundStyle(TTColor.textPrimary)
                            .frame(width: 18, height: 18)
                            .padding(-1)
                        Text("2:32 PM").font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28) // CSS content-box: 26 + 1-pt border each side
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255, opacity: 0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TTColor.borderCard))
                    Text(title).font(TTFont.sectionTitle).foregroundStyle(TTColor.textPrimary)
                    Text(text).font(TTFont.body12).lineSpacing(6).foregroundStyle(TTColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: 0x121317))
    }
}
