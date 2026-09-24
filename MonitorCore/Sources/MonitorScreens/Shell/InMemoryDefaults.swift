import Foundation
import os

/// A `UserDefaults` that never touches cfprefsd or disk: values live in this object only (renders, snapshot and
/// settings tests; no plist shared between concurrent test processes or worktrees, nothing left behind).
///
/// Every getter/setter family is overridden onto one in-memory store (plus registered defaults as the fallback
/// layer). As a second guard, the superclass is bound to a unique throwaway suite, never `.standard`, so any
/// API not overridden here can at worst touch that private suite, never the app's or the user's domains.
public final class InMemoryDefaults: UserDefaults {
    /// Values, then registered defaults. Immutable dictionary snapshots swapped under the lock; plist values are
    /// copied in, so the unchecked lock API never shares mutable state (`Any`/NSDictionary aren't Sendable).
    private let storage = OSAllocatedUnfairLock<(values: NSDictionary, registered: NSDictionary)>(
        uncheckedState: (NSDictionary(), NSDictionary()))

    public init() {
        super.init(suiteName: "dev.telltale.inmemory.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)")!
    }

    // MARK: Core

    public override func object(forKey defaultName: String) -> Any? {
        storage.withLockUnchecked { $0.values[defaultName] ?? $0.registered[defaultName] }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        let copy: Any? = (value as? NSCopying)?.copy(with: nil) ?? value
        storage.withLockUnchecked { s in
            let m = s.values.mutableCopy() as! NSMutableDictionary
            m[defaultName] = copy
            s.values = m.copy() as! NSDictionary
        }
    }

    public override func removeObject(forKey defaultName: String) {
        storage.withLockUnchecked { s in
            let m = s.values.mutableCopy() as! NSMutableDictionary
            m.removeObject(forKey: defaultName)
            s.values = m.copy() as! NSDictionary
        }
    }

    public override func register(defaults registrationDictionary: [String: Any]) {
        storage.withLockUnchecked { s in
            let m = s.registered.mutableCopy() as! NSMutableDictionary
            m.addEntries(from: registrationDictionary)
            s.registered = m.copy() as! NSDictionary
        }
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        storage.withLockUnchecked { s in
            var d = s.registered as? [String: Any] ?? [:]
            d.merge(s.values as? [String: Any] ?? [:]) { _, new in new }
            return d
        }
    }

    public override func synchronize() -> Bool { true }

    // MARK: Typed getters (UserDefaults semantics: numbers/strings coerced, missing → 0/false/nil)

    public override func string(forKey defaultName: String) -> String? {
        switch object(forKey: defaultName) {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    public override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
    public override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }
    public override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    public override func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    public override func integer(forKey defaultName: String) -> Int { number(defaultName)?.intValue ?? 0 }
    public override func float(forKey defaultName: String) -> Float { number(defaultName)?.floatValue ?? 0 }
    public override func double(forKey defaultName: String) -> Double { number(defaultName)?.doubleValue ?? 0 }
    public override func bool(forKey defaultName: String) -> Bool { number(defaultName)?.boolValue ?? false }

    public override func url(forKey defaultName: String) -> URL? {
        switch object(forKey: defaultName) {
        case let u as URL: u
        case let s as String: URL(string: s) ?? URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        case let d as Data: try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: d) as URL?
        default: nil
        }
    }

    private func number(_ key: String) -> NSNumber? {
        switch object(forKey: key) {
        case let n as NSNumber: n
        case let s as String: Double(s).map { NSNumber(value: $0) } ?? (s == "YES" || s == "true" ? 1 : nil)
        default: nil
        }
    }

    // MARK: Typed setters

    public override func set(_ value: Int, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    public override func set(_ value: Float, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    public override func set(_ value: Double, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    public override func set(_ value: Bool, forKey defaultName: String) { set(NSNumber(value: value), forKey: defaultName) }
    public override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
}
