import Testing
@testable import MonitorDiskTools

@Suite struct BundleIDTests {
    /// Bug caught: lowercasing before the uppercase team-ID strip leaves `74j34u3r6x.` on the ID, so Apple group
    /// containers look third-party and get offered as leftovers.
    @Test(arguments: [
        ("group.com.apple.VoiceMemos.shared", "com.apple.voicememos.shared", true),
        ("74J34U3R6X.com.apple.iWork", "com.apple.iwork", true),
        ("243LU875E5.groups.com.apple.podcasts", "com.apple.podcasts", true),
        ("com.foo.app.widgetextension", "com.foo.app.widgetextension", false),
        ("com.foo.App.savedState", "com.foo.app", false),
        ("com.foo.plist", "com.foo", false),
        ("com.Foo.cookies.binarycookies", "com.foo.cookies", false),
        // A 10-char lowercase prefix is not a team ID.
        ("abcdefghij.com.foo", "abcdefghij.com.foo", false),
    ])
    func normalizes(name: String, expected: String, apple: Bool) {
        #expect(BundleID.normalize(name) == expected)
        #expect(BundleID.isAppleOwned(expected) == apple)
    }

    /// Bug caught: `<TeamID>.<word>` and bare words flagged as leftovers of an uninstalled app.
    @Test(arguments: ["UBF8T346G9.Office", "Slack", "com", ".plist", "com..foo"])
    func rejectsNonBundleIDs(name: String) {
        #expect(BundleID.normalize(name) == nil)
    }
}
