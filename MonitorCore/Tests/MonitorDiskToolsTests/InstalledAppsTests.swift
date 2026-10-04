import Foundation
import MonitorModel
import Testing
@testable import MonitorDiskTools

@Suite struct InstalledAppsTests {
    private static func writeBundle(_ path: String, id: String, name: String? = nil, flatPlist: Bool = false) throws {
        let fm = FileManager.default
        let plistDir = flatPlist ? path : path + "/Contents"
        try fm.createDirectory(atPath: plistDir, withIntermediateDirectories: true)
        var dict: [String: Any] = ["CFBundleIdentifier": id]
        if let name { dict["CFBundleName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: plistDir + "/Info.plist"))
    }

    /// Bug caught: apps in the Trash, on other volumes or in App Translocation counted as installed (their data
    /// would be hidden from Leftovers), while helper-only apps are lost.
    @Test func filtersLocationsAndReadsNestedBundles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.writeBundle(home + "/Applications/Foo.app", id: "com.foo.Main", name: "Foo")
        try Self.writeBundle(home + "/Applications/Foo.app/Contents/PlugIns/Widget.appex", id: "com.foo.main.widget",
                             flatPlist: true)
        try Self.writeBundle(home + "/Applications/Foo.app/Contents/Library/LoginItems/Helper.app",
                             id: "com.foo.loginhelper")
        try Self.writeBundle(home + "/Applications/Setapp/Deep.app", id: "com.setapp.deep")
        try Self.writeBundle(home + "/Odd/Place.app", id: "org.odd.place")
        try Self.writeBundle(home + "/.Trash/Gone.app", id: "org.trashed.gone")
        try Self.writeBundle(home + "/AppTranslocation/ABC/d/Trans.app", id: "org.translocated.app")
        try Self.writeBundle(home + "/Applications/Wrapped.app", id: "org.wrapped.outer")
        try Self.writeBundle(home + "/Applications/Wrapped.app/Wrapper/Inner.app", id: "org.wrapped.inner",
                             flatPlist: true)

        let hits = [home + "/Odd/Place.app", home + "/.Trash/Gone.app", "/Volumes/Ext/Vol.app",
                    home + "/AppTranslocation/ABC/d/Trans.app"]
        let set = InstalledAppSet.build(home: home, mdfind: { hits })

        #expect(set.app(for: "com.foo.main")?.appPath == home + "/Applications/Foo.app")
        #expect(set.app(for: "com.foo.main")?.name == "Foo")
        // Nested IDs resolve to the host app.
        #expect(set.app(for: "com.foo.main.widget")?.bundleID == "com.foo.Main")
        #expect(set.app(for: "com.foo.loginhelper")?.bundleID == "com.foo.Main")
        #expect(set.app(for: "org.wrapped.inner")?.bundleID == "org.wrapped.outer")
        #expect(set.owns("com.setapp.deep"))
        #expect(set.owns("org.odd.place"))
        #expect(!set.owns("org.trashed.gone"))
        #expect(!set.owns("org.translocated.app"))
    }

    @Test func mdfindFailureStillUsesDirectoryScan() throws {
        struct Boom: Error {}
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Self.writeBundle(home + "/Applications/Foo.app", id: "com.foo.main")
        let set = InstalledAppSet.build(home: home, mdfind: { throw Boom() })
        #expect(set.owns("com.foo.main"))
    }

    /// Bug caught: an installed app's data offered as a leftover (relation missed), or `com.foobar` data hidden
    /// because the vendor check used a string prefix instead of components.
    @Test(arguments: [
        // (installed, candidate, owned)
        ("com.foo.app", "com.foo.app", true),
        ("com.foo.app", "com.foo.app.helper", true),
        ("com.foo.app", "helper.com.foo.app", true),
        ("com.foo.app.helper", "com.foo.app", true),
        ("com.foo.app", "com.foo.other", true),
        ("com.foo", "com.foobar", false),
        ("com.foo.app", "com.foobar.app", false),
        ("com.foo.app", "org.bar.app", false),
        ("com.foo.app", "foo.app", true),
    ])
    func ownership(installed: String, candidate: String, owned: Bool) {
        let set = InstalledAppSet(ids: [installed: OwnerApp(bundleID: installed, name: "X")])
        #expect(set.owns(candidate) == owned)
    }

    @Test func nearestRelationPicksOwner() {
        let set = InstalledAppSet(ids: [
            "com.foo.alpha": OwnerApp(bundleID: "com.foo.alpha", name: "Alpha"),
            "com.foo.beta": OwnerApp(bundleID: "com.foo.beta", name: "Beta"),
        ])
        #expect(set.app(for: "com.foo.beta.updater")?.name == "Beta")
        #expect(set.app(for: "com.foo.gamma")?.name == "Alpha")
    }
}
