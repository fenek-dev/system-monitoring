import Foundation
import MonitorModel

// W0b stub (ARCHITECTURE §5.1). W1 replaces this file.

public protocol AppResolving: AnyObject {
    func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity
    func prune(keeping live: Set<ProcessID>)
}

public final class BundleAppResolver: AppResolving {
    public init(currentUID: uid_t = getuid()) {}
    public func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity { AppIdentity() }
    public func prune(keeping live: Set<ProcessID>) {}
}

public final class FixtureAppResolver: AppResolving {
    public init(_ map: [Int32: AppIdentity]) {}
    public func identity(for process: RawProcess, responsible: RawProcess?) -> AppIdentity { AppIdentity() }
    public func prune(keeping live: Set<ProcessID>) {}
}
