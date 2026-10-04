import Foundation

public enum TrashError: Error, Equatable, Sendable {
    /// The volume has no Trash (or the system can't trash here). Never answered with a permanent delete.
    case noTrash
    case vanished
    case failed(String)
}

/// Moves one item to the Trash and returns where it landed.
public protocol TrashMover: Sendable {
    func trash(path: String) throws(TrashError) -> String
}

/// `FileManager.trashItem`: the system writes the Put Back metadata, which a plain rename into `.Trash` would not.
public struct SystemTrashMover: TrashMover {
    public init() {}

    public func trash(path: String) throws(TrashError) -> String {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        } catch let error as CocoaError {
            switch error.code {
            case .featureUnsupported: throw .noTrash
            case .fileNoSuchFile, .fileReadNoSuchFile: throw .vanished
            default: throw .failed(error.localizedDescription)
            }
        } catch {
            throw .failed(error.localizedDescription)
        }
        guard let resulting else { throw .failed("no resulting URL") }
        return (resulting as URL).path
    }
}

public enum EvictError: Error, Equatable, Sendable {
    case failed(String)
}

/// Drops the local copy of an iCloud file.
public protocol Evictor: Sendable {
    func evict(path: String) throws(EvictError)
}

public struct UbiquitousEvictor: Evictor {
    public init() {}

    public func evict(path: String) throws(EvictError) {
        do {
            try FileManager.default.evictUbiquitousItem(at: URL(fileURLWithPath: path))
        } catch {
            throw .failed(error.localizedDescription)
        }
    }
}
