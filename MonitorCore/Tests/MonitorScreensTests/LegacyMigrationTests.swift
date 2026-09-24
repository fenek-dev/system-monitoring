import Foundation
@testable import MonitorScreens
import Testing

/// Telltale → Warden one-time migration (Task 11): data dir move, defaults copy, login item, completion marker.
@Suite("Legacy migration") @MainActor
final class LegacyMigrationTests {
    let root: URL
    let old: URL
    let new: URL
    let oldDefaults = InMemoryDefaults()
    let newDefaults = InMemoryDefaults()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-migration-\(UUID().uuidString)")
        old = root.appendingPathComponent("dev.telltale", isDirectory: true)
        new = root.appendingPathComponent("dev.warden", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func seedOldData() throws {
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: old.appendingPathComponent("history.sqlite"))
    }

    private func domain(_ d: InMemoryDefaults) -> LegacyMigration.Domain {
        LegacyMigration.Domain(defaults: d, persisted: { d.dictionaryRepresentation() })
    }

    private func migration(running: Bool = false, legacyLogin: Bool = false, login: Bool = false,
                           enable: @escaping () throws -> Void = {}) -> LegacyMigration {
        LegacyMigration(legacyDataDirectory: old, dataDirectory: new,
                        defaults: [(from: domain(oldDefaults), to: domain(newDefaults))], marker: newDefaults,
                        legacyInstanceRunning: { running }, legacyLoginItemEnabled: { legacyLogin },
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

    @Test func existingNewDataAndDefaultsAreKept() throws {
        try seedOldData()
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        oldDefaults.set("fahrenheit", forKey: "units.temperature")
        newDefaults.set("celsius", forKey: "units.temperature")

        let r = migration().run()
        #expect(r.completed && r.data == .newAlreadyExists && r.copiedKeys == 0)
        #expect(FileManager.default.fileExists(atPath: old.appendingPathComponent("history.sqlite").path))
        #expect(newDefaults.string(forKey: "units.temperature") == "celsius")
    }

    @Test func nothingToMigrateStillCompletes() {
        let r = migration().run()
        #expect(r.completed && r.data == .noLegacyData && r.copiedKeys == 0 && !r.loginItemRegistered)
        #expect(newDefaults.bool(forKey: LegacyMigration.doneKey))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    /// A running Telltale owns the old store and domain: touch nothing and retry next launch.
    @Test func runningLegacyInstanceDefersEverything() throws {
        try seedOldData()
        oldDefaults.set(true, forKey: "overlay.enabled")
        let r = migration(running: true).run()
        #expect(!r.completed && r.data == .legacyInUse && r.copiedKeys == 0)
        #expect(FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: new.path))
        #expect(!newDefaults.bool(forKey: LegacyMigration.doneKey) && !newDefaults.bool(forKey: "overlay.enabled"))
    }

    @Test func perDataDirSuiteIsCopiedToo() {
        let oldSuite = InMemoryDefaults(), newSuite = InMemoryDefaults()
        oldSuite.set(0.55, forKey: "overlay.opacity")
        let m = LegacyMigration(legacyDataDirectory: nil, dataDirectory: nil,
                                defaults: [(from: domain(oldDefaults), to: domain(newDefaults)),
                                           (from: domain(oldSuite), to: domain(newSuite))],
                                marker: newDefaults, legacyInstanceRunning: { false },
                                legacyLoginItemEnabled: { false }, loginItemEnabled: { false }, enableLoginItem: {})
        let r = m.run()
        #expect(r.completed && r.data == nil && r.copiedKeys == 1)
        #expect(newSuite.double(forKey: "overlay.opacity") == 0.55)
    }

    @Test func loginItemFollowsTheLegacyRegistration() {
        var calls = 0
        let r = migration(legacyLogin: true, enable: { calls += 1 }).run()
        #expect(r.loginItemRegistered && calls == 1)
    }

    @Test func loginItemLeftAloneWhenLegacyWasOffOrNewIsOn() throws {
        var calls = 0
        #expect(!migration(legacyLogin: false, enable: { calls += 1 }).run().loginItemRegistered)
        newDefaults.removeObject(forKey: LegacyMigration.doneKey)
        #expect(!migration(legacyLogin: true, login: true, enable: { calls += 1 }).run().loginItemRegistered)
        #expect(calls == 0)
    }

    @Test func failedLoginRegistrationStillCompletes() {
        struct Denied: Error {}
        let r = migration(legacyLogin: true, enable: { throw Denied() }).run()
        #expect(r.completed && !r.loginItemRegistered)
    }
}
