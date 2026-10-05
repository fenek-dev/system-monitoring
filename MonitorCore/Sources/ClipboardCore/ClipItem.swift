import Foundation

public enum ClipKind: String, Sendable, Codable, CaseIterable { case text, image, files }

/// A history row. Never holds a full large payload: `text` is capped at `ClipboardPolicy.previewCharacters`.
public struct ClipItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var kind: ClipKind
    public var text: String
    public var textLength: Int
    public var files: [String]
    public var imageFile: String?
    public var thumbFile: String?
    public var imageWidth: Int
    public var imageHeight: Int
    public var byteSize: Int64
    public var hash: String
    public var sourceBundleID: String?
    public var sourceName: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var pinned: Bool

    public init(
        id: Int64,
        kind: ClipKind,
        text: String = "",
        textLength: Int = 0,
        files: [String] = [],
        imageFile: String? = nil,
        thumbFile: String? = nil,
        imageWidth: Int = 0,
        imageHeight: Int = 0,
        byteSize: Int64 = 0,
        hash: String = "",
        sourceBundleID: String? = nil,
        sourceName: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        lastUsedAt: Date = Date(timeIntervalSince1970: 0),
        pinned: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.textLength = textLength
        self.files = files
        self.imageFile = imageFile
        self.thumbFile = thumbFile
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.byteSize = byteSize
        self.hash = hash
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.pinned = pinned
    }

    /// One-line label: text → first non-empty line with whitespace runs collapsed; image → "Image 1280 × 720";
    /// files → file name, or "name and N more".
    public var preview: String {
        switch kind {
        case .text:
            for line in text.split(whereSeparator: \.isNewline) {
                let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !collapsed.isEmpty { return collapsed }
            }
            return ""
        case .image:
            return "Image \(imageWidth) × \(imageHeight)"
        case .files:
            guard let first = fileNames.first else { return "" }
            let others = fileNames.count - 1
            return others > 0 ? "\(first) and \(others) more" : first
        }
    }

    /// What the fuzzy matcher searches besides the source app name.
    public var searchText: String {
        switch kind {
        case .text: text
        case .image: "Image"
        case .files: fileNames.joined(separator: " ")
        }
    }

    private var fileNames: [String] { files.map { ($0 as NSString).lastPathComponent } }
}
