import Foundation

/// Memory for restricted pids: setuid `/bin/ps -axo pid=,rss=` (KB → bytes), run on its own queue.
public struct RootMemoryReading: Sendable, Codable {
    public var rssByPID: [Int32: UInt64]

    public init(rssByPID: [Int32: UInt64] = [:]) {
        self.rssByPID = rssByPID
    }
}
