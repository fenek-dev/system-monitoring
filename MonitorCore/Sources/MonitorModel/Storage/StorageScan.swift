import Foundation

public enum ScanRoot: Hashable, Codable, Sendable {
    case home(String)
    case folder(String)
    /// `name` is the user-facing volume name ("Macintosh HD" for the Data volume).
    case volume(path: String, name: String)

    public var path: String {
        switch self {
        case let .home(path), let .folder(path), let .volume(path, _): path
        }
    }

    /// Cleanup mode only runs on the home root (spec §4.4); other roots get Space Map + Move to Trash.
    public var allowsCleanup: Bool {
        if case .home = self { return true }
        return false
    }
}

public struct ScanProgress: Equatable, Sendable {
    public var files: Int
    public var bytes: UInt64
    public var currentPath: String

    public init(files: Int, bytes: UInt64, currentPath: String) {
        self.files = files
        self.bytes = bytes
        self.currentPath = currentPath
    }
}

public enum ScanFailure: Equatable, Error, Sendable {
    case volumeRemoved
    case rootUnreadable(String)
    case cancelled
    case io(String)
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case partial(StorageTree)
    case finished(StorageTree)
    /// After classify; sent again after ownership resolution and again when private sizes are final.
    case classified(CleanupSet)
    case failed(ScanFailure)
}
