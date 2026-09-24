import Foundation
import os

/// A `UserDefaults` that never touches cfprefsd or disk: values live in this object only (renders, snapshot and
/// settings tests; no plist shared between concurrent test processes or worktrees, nothing left behind).
/// `SettingsStore` reads through `object/string/array/bool(forKey:)` and writes through `set(_:forKey:)` /
/// `removeObject(forKey:)`, all overridden here.
public final class InMemoryDefaults: UserDefaults {
    /// Immutable dictionary snapshots swapped under the lock; plist values are copied in, so the unchecked lock
    /// API never shares mutable state (`Any`/NSDictionary aren't Sendable).
    private let storage = OSAllocatedUnfairLock<NSDictionary>(uncheckedState: NSDictionary())

    public init() {
        super.init(suiteName: nil)!
    }

    public override func object(forKey defaultName: String) -> Any? {
        storage.withLockUnchecked { $0[defaultName] }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        // Plist values are copied in, so nothing mutable is shared; `withLockUnchecked` because `Any` isn't Sendable.
        let copy: Any? = (value as? NSCopying)?.copy(with: nil) ?? value
        storage.withLockUnchecked { dict in
            let m = dict.mutableCopy() as! NSMutableDictionary
            m[defaultName] = copy
            dict = m.copy() as! NSDictionary
        }
    }

    public override func removeObject(forKey defaultName: String) {
        storage.withLockUnchecked { dict in
            let m = dict.mutableCopy() as! NSMutableDictionary
            m.removeObject(forKey: defaultName)
            dict = m.copy() as! NSDictionary
        }
    }

    public override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    public override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    public override func bool(forKey defaultName: String) -> Bool { object(forKey: defaultName) as? Bool ?? false }
    public override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    public override func dictionaryRepresentation() -> [String: Any] {
        storage.withLockUnchecked { $0 as? [String: Any] ?? [:] }
    }
    public override func synchronize() -> Bool { true }
}
