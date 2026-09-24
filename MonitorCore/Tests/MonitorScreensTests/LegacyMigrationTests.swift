import Foundation
@testable import MonitorScreens
import Testing

/// Telltale → Warden one-time migration (Task 11): data dir move, defaults copy, login item, notice, marker.
@Suite("Legacy migration") @MainActor
final class LegacyMigrationTests {
    let root: URL
    let old: URL
    let new: URL
    let oldDefaults = InMemoryDefaults()
    let newDefaults = InMemoryDefaults()
    /// Number of `replace` calls per domain object (one-pass write check).
    var replaces: [ObjectIdentifier: Int] = [:]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)")
        old = root.appendingPathComponent("dev.telltale", isDirectory: true)
        new = root.appendingPathComponent("dev.warden", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        let ro = root.appendingPathComponent("ro").path
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ro)
        try? FileManager.default.removeItem(at: root)
    }

    private func seedOldData() throws {
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: old.appendingPathComponent("history.sqlite"))
    }

    private func domain(_ d: InMemoryDefaults) -> LegacyMigration.Domain {
        LegacyMigration.Domain(persisted: { d.dictionaryRepresentation() }, replace: { [weak self] dict in
            self?.replaces[ObjectIdentifier(d), default: 0] += 1
            for k in d.dictionaryRepresentation().keys where dict[k] == nil { d.removeObject(forKey: k) }
            for (k, v) in dict { d.set(v, forKey: k) }
        })
    }

    private func migration(to newDir: URL? = nil, running: Bool = false, login: Bool = false,
                           enable: @escaping () throws -> Void = {}) -> LegacyMigration {
        LegacyMigration(legacyDataDirectory: old, dataDirectory: newDir ?? new,
                        defaults: [(from: domain(oldDefaults), to: domain(newDefaults))], marker: newDefaults,
                        lockLegacy: { running ? .heldByTelltale : .acquired(nil) },
                        legacyLoginItem: { $0["test.launchAtLogin"] as? Bool },
                        loginItemEnabled: { login }, enableLoginItem: enable)
    }

    @Test func movesDataAndCopiesDefaultsOnce() throws {
        try seedOldData()
        oldDefaults.set(true, forKey: "overlay.enabled")
        oldDefaults.set("fahrenheit", forKey: "units.temperature")

        let first = migration().run()
        #expect(first.completed && !first.alreadyDone)
        #expect(first.data == .moved)
        #expect(first.copiedKeys == 2)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("history.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(newDefaults.bool(forKey: "overlay.enabled"))
        #expect(newDefaults.string(forKey: "units.temperature") == "fahrenheit")
        #expect(newDefaults.bool(forKey: LegacyMigration.doneKey))

        // Second launch: marker set → nothing happens, even if the old domain changed meanwhile.
        oldDefaults.set("celsius", forKey: "units.temperature")
        let second = migration().run()
        #expect(second.alreadyDone && second.data == nil && second.copiedKeys == 0)
        #expect(newDefaults.string(forKey: "units.temperature") == "fahrenheit")
    }

    /// Fix 4: all old keys land in one `replace` (setPersistentDomain), not key by key.
    @Test func defaultsAreWrittenInOnePass() {
        for i in 0..<5 { oldDefaults.set(i, forKey: "k\(i)") }
        let r = migration().run()
        #expect(r.copiedKeys == 5)
        #expect(replaces[ObjectIdentifier(newDefaults)] == 1)
        #expect((0..<5).allSatisfy { newDefaults.integer(forKey: "k\($0)") == $0 })
    }

    @Test func existingNewDataAndDefaultsAreKept() throws {
        try seedOldData()
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("real".utf8).write(to: new.appendingPathComponent("history.sqlite"))   // Warden data: keep
        oldDefaults.set("fahrenheit", forKey: "units.temperature")
        newDefaults.set("celsius", forKey: "units.temperature")

        let r = migration().run()
        #expect(r.completed && r.data == .newAlreadyExists && r.copiedKeys == 0)
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("history.sqlite").path))
        #expect(newDefaults.string(forKey: "units.temperature") == "celsius")
        #expect(replaces[ObjectIdentifier(newDefaults)] == nil)
    }

    @Test func nothingToMigrateStillCompletesWithoutNotice() {
        let r = migration().run()
        #expect(r.completed && r.data == .noLegacyData && r.copiedKeys == 0 && !r.loginItemRegistered)
        #expect(newDefaults.bool(forKey: LegacyMigration.doneKey))
        #expect(!FileManager.default.fileExists(atPath: new.path))
        #expect(!LegacyMigration.takeNotice(newDefaults))
    }

    /// A running Telltale owns the old store and domain: touch nothing and retry next launch.
    @Test func runningLegacyInstanceDefersEverything() throws {
        try seedOldData()
        oldDefaults.set(true, forKey: "overlay.enabled")
        let r = migration(running: true).run()
        #expect(!r.completed && r.data == .legacyInUse && r.copiedKeys == 0)
        #expect(FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: new.path))
        #expect(!newDefaults.bool(forKey: LegacyMigration.doneKey) && !newDefaults.bool(forKey: "overlay.enabled"))
        #expect(!LegacyMigration.takeNotice(newDefaults))
    }

    /// Final review 1: a launch deferred by a running Telltale creates no Warden dir; the next launch (Telltale
    /// quit) migrates everything.
    @Test func launchAfterADeferralMigrates() throws {
        try seedOldData()
        oldDefaults.set(true, forKey: "overlay.enabled")
        #expect(migration(running: true).run().data == .legacyInUse)
        #expect(!FileManager.default.fileExists(atPath: new.path))
        let r = migration().run()
        #expect(r.completed && r.data == .moved && r.copiedKeys == 1)
        #expect(FileManager.default.fileExists(atPath: new.appendingPathComponent("history.sqlite").path))
        #expect(newDefaults.bool(forKey: "overlay.enabled"))
    }

    /// A new dir left by an earlier launch that couldn't migrate (lock file, empty store) is replaced.
    @Test func disposableNewDirIsReplaced() throws {
        try seedOldData()
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try Data().write(to: new.appendingPathComponent(".instance.lock"))
        try Data().write(to: new.appendingPathComponent("history.sqlite"))
        #expect(LegacyMigration.onlyLockOrEmptyFiles(new))
        let r = migration().run()
        #expect(r.data == .moved)
        #expect(try Data(contentsOf: new.appendingPathComponent("history.sqlite")) == Data("db".utf8))
    }

    /// The old dir's lock token lives until the migration returns (held through the move and the defaults copy).
    @Test func legacyLockIsHeldThroughTheMigration() throws {
        final class Token {}
        try seedOldData()
        oldDefaults.set(1, forKey: "k")
        weak var weakToken: Token?
        var aliveDuringCopy = false
        let m = LegacyMigration(
            legacyDataDirectory: old, dataDirectory: new,
            defaults: [(from: domain(oldDefaults),
                        to: LegacyMigration.Domain(persisted: { [:] }, replace: { _ in aliveDuringCopy = weakToken != nil }))],
            marker: newDefaults,
            lockLegacy: {
                let t = Token()
                weakToken = t
                return .acquired(t)
            })
        #expect(m.run().data == .moved)
        #expect(aliveDuringCopy)
        #expect(weakToken == nil)
    }

    /// Fix 3: a failed move (unwritable parent) copies no defaults and writes no marker; the next launch retries.
    @Test func failedMoveStopsBeforeDefaultsAndMarker() throws {
        try seedOldData()
        oldDefaults.set(true, forKey: "overlay.enabled")
        let ro = root.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: ro.path)
        let r = migration(to: ro.appendingPathComponent("dev.warden", isDirectory: true)).run()
        guard case .failed = r.data else {
            Issue.record("expected .failed, got \(String(describing: r.data))")
            return
        }
        #expect(!r.completed && r.copiedKeys == 0)
        #expect(!newDefaults.bool(forKey: LegacyMigration.doneKey) && !newDefaults.bool(forKey: "overlay.enabled"))
        #expect(!LegacyMigration.takeNotice(newDefaults))
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("history.sqlite").path))
    }

    @Test func perDataDirSuiteIsCopiedToo() {
        let oldSuite = InMemoryDefaults(), newSuite = InMemoryDefaults()
        oldSuite.set(0.55, forKey: "overlay.opacity")
        let m = LegacyMigration(legacyDataDirectory: nil, dataDirectory: nil,
                                defaults: [(from: domain(oldDefaults), to: domain(newDefaults)),
                                           (from: domain(oldSuite), to: domain(newSuite))],
                                marker: newDefaults)
        let r = m.run()
        #expect(r.completed && r.data == nil && r.copiedKeys == 1)
        #expect(newSuite.double(forKey: "overlay.opacity") == 0.55)
    }

    /// Fix 2: shown once after a migration that moved something, then never again.
    @Test func noticeIsPendingOnceAfterAMigration() throws {
        try seedOldData()
        _ = migration().run()
        #expect(LegacyMigration.takeNotice(newDefaults))
        #expect(!LegacyMigration.takeNotice(newDefaults))
        _ = migration().run()                                        // already done: no new notice
        #expect(!LegacyMigration.takeNotice(newDefaults))
        #expect(LegacyMigration.noticeText.contains("System Settings › General › Login Items"))
        #expect(LegacyMigration.noticeText.contains(LegacyMigration.noticeLoginButton))
        #expect(!LegacyMigration.noticeTextWithoutLogin.contains(LegacyMigration.noticeLoginButton))
    }

    @Test func loginItemOnlyWhenTheOldDefaultsRecordIt() {
        var calls = 0
        oldDefaults.set(true, forKey: "test.launchAtLogin")
        #expect(migration(enable: { calls += 1 }).run().loginItemRegistered)
        #expect(calls == 1)
    }

    @Test func loginItemLeftAloneWhenNotRecordedOffOrAlreadyOn() {
        var calls = 0
        oldDefaults.set(1, forKey: "other")                              // not recorded → nothing
        #expect(!migration(enable: { calls += 1 }).run().loginItemRegistered)
        for (recorded, on) in [(false, false), (true, true)] {
            newDefaults.removeObject(forKey: LegacyMigration.doneKey)
            oldDefaults.set(recorded, forKey: "test.launchAtLogin")
            #expect(!migration(login: on, enable: { calls += 1 }).run().loginItemRegistered)
        }
        #expect(calls == 0)
    }

    @Test func failedLoginRegistrationStillCompletes() {
        struct Denied: Error {}
        oldDefaults.set(true, forKey: "test.launchAtLogin")
        let r = migration(enable: { throw Denied() }).run()
        #expect(r.completed && !r.loginItemRegistered)
    }
}
