import CryptoKit
import Foundation

public struct ClipSource: Equatable, Sendable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String? = nil, name: String? = nil) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// One pasteboard value ready to be stored.
public struct ClipCapture: Equatable, Sendable {
    public enum Content: Equatable, Sendable { case text(String), image(Data), files([String]) }

    public var content: Content
    public var source: ClipSource

    public init(content: Content, source: ClipSource = ClipSource()) {
        self.content = content
        self.source = source
    }

    public var kind: ClipKind {
        switch content {
        case .text: .text
        case .image: .image
        case .files: .files
        }
    }

    /// SHA-256 hex over a kind tag plus the content, so equal bytes of different kinds never collide.
    public var hash: String {
        var hasher = SHA256()
        switch content {
        case .text(let text):
            hasher.update(data: Data("text\0".utf8))
            hasher.update(data: Data(text.utf8))
        case .image(let data):
            hasher.update(data: Data("image\0".utf8))
            hasher.update(data: data)
        case .files(let paths):
            hasher.update(data: Data("files\0".utf8))
            hasher.update(data: Data(paths.joined(separator: "\0").utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
