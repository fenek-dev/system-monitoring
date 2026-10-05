import Foundation

/// Limits for what is recorded and how long it is kept. Tests lower them to keep fixtures small.
public struct ClipboardPolicy: Equatable, Sendable {
    public var maxItems = 500
    public var maxAge: TimeInterval = 30 * 86_400
    public var maxImageBytes = 20 * 1_048_576
    public var maxTotalImageBytes: Int64 = 500 * 1_048_576
    public var maxTextBytes = 2 * 1_048_576
    public var previewCharacters = 2_000
    public var thumbnailPixels = 128

    public init() {}

    public static let `default` = ClipboardPolicy()
}
