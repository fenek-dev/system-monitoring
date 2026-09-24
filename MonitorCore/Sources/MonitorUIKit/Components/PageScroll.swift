import SwiftUI

/// Dashboard page content (DESIGN §3.0 "Content"): leading VStack gap 12, padding 20 on all sides, on `bgWindow`.
/// Scrolls vertically; in snapshots (`isSnapshot`) it is a plain VStack filling the frame so the render is
/// deterministic and flex children (bottom table card) take the remaining height.
public struct PageScroll<Content: View>: View {
    private let content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    public init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: TTSpace.gridGap) { content }
            .padding(TTSpace.pagePadding)
    }

    public var body: some View {
        if isSnapshot {
            stack.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(TTColor.bgWindow)
        } else {
            ScrollView(.vertical) {
                stack.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.automatic)
            .background(TTColor.bgWindow)
        }
    }
}
