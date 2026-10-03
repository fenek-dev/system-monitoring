import Darwin

public struct AudioProcess: Equatable, Sendable {
    public let objectID: UInt32
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool

    public init(objectID: UInt32, pid: pid_t, bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

public struct ProcessTree {
    /// pid to bundle ID, for apps with a regular activation policy.
    public var regularApps: [pid_t: String]
    public var responsible: (pid_t) -> pid_t?
    public var parent: (pid_t) -> pid_t?

    public init(regularApps: [pid_t: String], responsible: @escaping (pid_t) -> pid_t?, parent: @escaping (pid_t) -> pid_t?) {
        self.regularApps = regularApps
        self.responsible = responsible
        self.parent = parent
    }
}

public struct AppGroup: Equatable, Sendable {
    public let id: String
    public var objectIDs: [UInt32]
    public var isPlaying: Bool
    public var isRegularApp: Bool

    public init(id: String, objectIDs: [UInt32], isPlaying: Bool, isRegularApp: Bool) {
        self.id = id
        self.objectIDs = objectIDs
        self.isPlaying = isPlaying
        self.isRegularApp = isRegularApp
    }
}

public enum AppGrouping {
    public static func owner(of process: AudioProcess, in tree: ProcessTree) -> (id: String, isRegularApp: Bool)? {
        if let id = tree.regularApps[process.pid] { return (id, true) }
        if let responsible = tree.responsible(process.pid), let id = tree.regularApps[responsible] {
            return (id, true)
        }
        var pid = process.pid
        for _ in 0..<16 {
            guard let next = tree.parent(pid), next > 1, next != pid else { break }
            if let id = tree.regularApps[next] { return (id, true) }
            pid = next
        }
        guard let bundleID = process.bundleID, !bundleID.isEmpty else { return nil }
        let prefixMatch = tree.regularApps.values
            .filter { bundleID.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
        if let prefixMatch { return (prefixMatch, true) }
        return (bundleID, false)
    }

    public static func group(_ processes: [AudioProcess], in tree: ProcessTree, excluding selfPID: pid_t) -> [AppGroup] {
        var groups: [String: AppGroup] = [:]
        for process in processes where process.pid != selfPID {
            guard let owner = owner(of: process, in: tree) else { continue }
            var group = groups[owner.id] ?? AppGroup(id: owner.id, objectIDs: [], isPlaying: false, isRegularApp: owner.isRegularApp)
            group.objectIDs.append(process.objectID)
            group.isPlaying = group.isPlaying || process.isRunningOutput
            groups[owner.id] = group
        }
        return groups.values
            .map { group in
                var sorted = group
                sorted.objectIDs.sort()
                return sorted
            }
            .sorted { $0.id < $1.id }
    }
}
