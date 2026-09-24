import MonitorModel
import SwiftUI

@MainActor enum GallerySamples {
    static var items: [TTGallery.Item] {
        [
            .init(id: "icons", size: CGSize(width: 560, height: 40)) { AnyView(IconsSample()) },
            .init(id: "type", size: CGSize(width: 560, height: 120)) { AnyView(TypeSample()) },
        ]
    }
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
