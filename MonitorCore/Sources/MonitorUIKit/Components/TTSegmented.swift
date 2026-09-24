import SwiftUI

/// DESIGN §2.13 segmented control. Regular: container HStack gap 2, padding 2, radius 7, `fillField`, height 28;
/// segment height 24, padding 10, radius 5, `button12`. Compact: container radius 6, height 24; segment height 20,
/// padding 8, radius 4, `captionMedium`. On = `fillSegmentOn` + `textPrimary`; off = `textSecondary`; hover
/// (off) = `fillHover`. Switches instantly (no animation).
public struct TTSegmented<T: Hashable>: View {
    @Binding private var selection: T
    private let options: [(T, String)]
    private let compact: Bool

    public init(selection: Binding<T>, options: [(T, String)], compact: Bool = false) {
        _selection = selection
        self.options = options
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: TTSpace.x2) {
            ForEach(options.indices, id: \.self) { i in
                Segment(title: options[i].1, isOn: options[i].0 == selection, compact: compact) {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { selection = options[i].0 }
                }
            }
        }
        .padding(TTSpace.x2)
        .background(
            RoundedRectangle(cornerRadius: compact ? TTRadius.r6 : TTRadius.r7, style: .continuous)
                .fill(TTColor.fillField)
        )
        .fixedSize()
    }

    private struct Segment: View {
        let title: String
        let isOn: Bool
        let compact: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(compact ? TTFont.captionMedium : TTFont.button12)
                    .foregroundStyle(isOn ? TTColor.textPrimary : TTColor.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, compact ? TTSpace.x8 : TTSpace.x10)
                    .frame(height: compact ? 20 : 24)
                    .background(
                        RoundedRectangle(cornerRadius: compact ? TTRadius.r4 : TTRadius.r5, style: .continuous)
                            .fill(isOn ? TTColor.fillSegmentOn : (hovering ? TTColor.fillHover : .clear))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(isOn ? .isSelected : [])
        }
    }
}
