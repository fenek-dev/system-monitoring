import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

public struct TTCard<Content: View>: View {
    private let content: Content

    public init(padding: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View { content }
}

public struct TTCardHeader<Trailing: View>: View {
    private let title: String
    private let trailing: Trailing

    public init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    public var body: some View {
        HStack {
            Text(title)
            Spacer()
            trailing
        }
    }
}
