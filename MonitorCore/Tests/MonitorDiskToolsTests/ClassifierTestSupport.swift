import Foundation
import MonitorModel
import Synchronization
@testable import MonitorDiskTools

/// Git fake: `tracked` dirs report tracked files, `failClosed` mimics a timeout or error (also "tracked").
struct FakeGit: GitTracking {
    var tracked: Set<String> = []
    var failClosed = false

    func hasTrackedFiles(project: String, dir: String) -> Bool {
        failClosed || tracked.contains(dir)
    }
}

final class FakeDevTools: DevToolProbe, Sendable {
    let xcodeSelectOK: Bool
    let udids: [String]
    private let simulatorCalls = Mutex(0)

    init(xcodeSelectOK: Bool = true, udids: [String] = []) {
        self.xcodeSelectOK = xcodeSelectOK
        self.udids = udids
    }

    var simulatorQueries: Int { simulatorCalls.withLock { $0 } }

    func unavailableSimulatorUDIDs() -> [String] {
        simulatorCalls.withLock { $0 += 1 }
        return udids
    }
}

enum ClassifierFixture {
    static let home = "/Users/test"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let mb: UInt64 = 1_000_000

    /// Unix time `days` before `now`.
    static func ago(_ days: Double) -> Int64 {
        Int64(now.timeIntervalSince1970 - days * 86400)
    }

    static func classifier(
        git: any GitTracking = FakeGit(), devTools: any DevToolProbe = FakeDevTools(),
        dataDirectories: [String] = [], ubiquitous: Set<String> = []
    ) -> Classifier {
        Classifier(home: home, dataDirectories: dataDirectories, git: git, devTools: devTools,
                   isUbiquitous: { ubiquitous.contains($0) })
    }

    static func classify(
        _ entries: [TreeFixture.Entry], installed: InstalledAppSet = InstalledAppSet(ids: [:]),
        lastUsed: [String: Date] = [:], options: ClassifyOptions? = nil, classifier: Classifier = classifier()
    ) -> ClassifyResult {
        let tree = TreeFixture.build(entries)
        return classifier.classify(tree: tree, installed: installed, lastUsed: lastUsed,
                                   options: options ?? ClassifyOptions(now: now))
    }

    static func paths(_ set: CleanupSet, _ category: CleanupCategory? = nil) -> [String] {
        set.items.filter { category == nil || $0.category == category }.map(\.path)
    }

    /// A dir that is `bytes` big and was last touched `days` ago.
    static func aged(_ name: String, days: Double, bytes: UInt64 = 1000, markers: StorageMarker = [],
                     flags: StorageNodeFlags = [], _ children: [TreeFixture.Entry] = []) -> TreeFixture.Entry {
        TreeFixture.dir(name, flags: flags, markers: markers, mtime: ago(days),
                        children + [TreeFixture.small(bytes: bytes, maxMtime: ago(days))])
    }
}
