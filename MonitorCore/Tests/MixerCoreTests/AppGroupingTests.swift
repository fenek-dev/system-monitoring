import Darwin
import Testing
@testable import MixerCore

struct AppGroupingTests {
    private func tree(
        regular: [pid_t: String],
        responsible: [pid_t: pid_t] = [:],
        parents: [pid_t: pid_t] = [:]
    ) -> ProcessTree {
        ProcessTree(regularApps: regular, responsible: { responsible[$0] }, parent: { parents[$0] })
    }

    private func process(_ objectID: UInt32, pid: pid_t, bundleID: String?, playing: Bool = false) -> AudioProcess {
        AudioProcess(objectID: objectID, pid: pid, bundleID: bundleID, isRunningOutput: playing)
    }

    @Test func regularAppOwnsItself() {
        let owner = AppGrouping.owner(of: process(1, pid: 10, bundleID: "com.apple.Music"), in: tree(regular: [10: "com.apple.Music"]))
        #expect(owner?.id == "com.apple.Music")
        #expect(owner?.isRegularApp == true)
    }

    @Test func responsiblePidWinsOverParent() {
        let tree = tree(regular: [10: "com.apple.Safari", 20: "com.example.Other"], responsible: [30: 10], parents: [30: 20])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.apple.WebKit.GPU"), in: tree)?.id == "com.apple.Safari")
    }

    @Test func walksParentChain() {
        let tree = tree(regular: [10: "com.google.Chrome"], parents: [30: 20, 20: 10])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.google.Chrome.helper"), in: tree)?.id == "com.google.Chrome")
    }

    @Test func parentCycleTerminates() {
        let tree = tree(regular: [:], parents: [30: 31, 31: 30])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: nil), in: tree) == nil)
    }

    @Test func stopsAtLaunchd() {
        let tree = tree(regular: [1: "bogus"], parents: [30: 1])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.example.daemon"), in: tree)?.id == "com.example.daemon")
    }

    @Test func prefixFallbackPicksLongestMatchAtDotBoundary() {
        let tree = tree(regular: [10: "com.example.App", 11: "com.example.App.Pro", 12: "com.example.Ap"])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.example.App.Pro.helper"), in: tree)?.id == "com.example.App.Pro")
        #expect(AppGrouping.owner(of: process(2, pid: 31, bundleID: "com.example.App.helper"), in: tree)?.id == "com.example.App")
    }

    @Test func unknownProcessWithBundleIDOwnsItself() {
        let owner = AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.example.daemon"), in: tree(regular: [:]))
        #expect(owner?.id == "com.example.daemon")
        #expect(owner?.isRegularApp == false)
    }

    @Test func processWithoutBundleIDOrOwnerIsSkipped() {
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: nil), in: tree(regular: [:])) == nil)
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: ""), in: tree(regular: [:])) == nil)
    }

    @Test func groupsHelpersUnderOneApp() {
        let tree = tree(regular: [10: "com.google.Chrome"], parents: [30: 10, 31: 10])
        let groups = AppGrouping.group([
            process(7, pid: 31, bundleID: "com.google.Chrome.helper", playing: true),
            process(5, pid: 30, bundleID: "com.google.Chrome.helper"),
            process(9, pid: 40, bundleID: nil),
        ], in: tree, excluding: 999)
        #expect(groups == [AppGroup(id: "com.google.Chrome", objectIDs: [5, 7], isPlaying: true, isRegularApp: true)])
    }

    @Test func excludesOwnProcess() {
        let tree = tree(regular: [10: "local.volumemixer.VolumeMixer"])
        #expect(AppGrouping.group([process(1, pid: 10, bundleID: "local.volumemixer.VolumeMixer")], in: tree, excluding: 10).isEmpty)
    }
}
