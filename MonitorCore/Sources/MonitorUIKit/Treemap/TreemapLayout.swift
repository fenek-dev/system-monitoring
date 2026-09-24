import CoreGraphics

// W0b placeholder (ARCHITECTURE §5.12). W3 replaces this file.

/// DESIGN §2.28: squarified, sorted desc, "other" laid out last (bottom-right).
public enum TreemapLayout {
    /// Results in input order.
    public static func squarify(_ values: [Double], otherIndex: Int?, in rect: CGRect) -> [CGRect] {
        Array(repeating: .zero, count: values.count)
    }

    public static func worstAspectRatio(_ rects: [CGRect]) -> Double { 0 }
}
