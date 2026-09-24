import SwiftUI

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

public struct TTSegmented<T: Hashable>: View {
    public init(selection: Binding<T>, options: [(T, String)], compact: Bool = false) {}

    public var body: some View { EmptyView() }
}
