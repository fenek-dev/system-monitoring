import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

/// Plain VStack when isSnapshot.
public struct PageScroll<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView { VStack { content } }
    }
}
