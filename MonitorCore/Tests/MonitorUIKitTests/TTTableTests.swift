import AppKit
import MonitorModel
import MonitorSnapshotTesting
import SwiftUI
import Testing
@testable import MonitorUIKit

@Suite struct TTTableTests {
    struct R: Identifiable, Equatable {
        var id: String
        var cpu: Double?
        var kids: [R] = []
    }

    typealias T = TTTable<R>
    let key: (R) -> Double? = { $0.cpu }

    @Test func sortsDescendingWithNilsLastAndStableTies() {
        let rows = [R(id: "a", cpu: 1), R(id: "b", cpu: nil), R(id: "c", cpu: 5), R(id: "d", cpu: 1), R(id: "e", cpu: 9)]
        #expect(T.sorted(rows, key: key, descending: true).map(\.id) == ["e", "c", "a", "d", "b"])
        #expect(T.sorted(rows, key: key, descending: false).map(\.id) == ["a", "d", "c", "e", "b"])
        #expect(T.sorted(rows, key: nil, descending: true).map(\.id) == rows.map(\.id))
    }

    @Test func linesFlattenExpandedChildrenWithParentParity() {
        let rows = [
            R(id: "p0", cpu: 3, kids: [R(id: "c0", cpu: 1), R(id: "c1", cpu: 2)]),
            R(id: "p1", cpu: 2),
            R(id: "p2", cpu: 1, kids: [R(id: "c2", cpu: 1)]),
        ]
        let lines = T.lines(rows, key: key, descending: true, children: { $0.kids }, expanded: ["p0"])
        #expect(lines.map(\.row.id) == ["p0", "c1", "c0", "p1", "p2"])
        #expect(lines.map(\.depth) == [0, 1, 1, 0, 0])
        #expect(lines.map(\.parity) == [0, 0, 0, 1, 0])
        #expect(lines.map(\.hasChildren) == [true, false, false, false, true])
        #expect(lines.map(\.isExpanded) == [true, false, false, false, false])
    }

    @Test func columnWidthsSplitRemainingSpace() {
        let widths = T.columnWidths([.fraction(2.2, min: 0), .fixed(64), .fraction(1, min: 0), .flexible(min: 50)],
                                    available: 1000, gap: 12)
        // 1000 − 3·12 − 64 = 900 over weights 2.2 + 1 + 1.
        #expect(abs(widths[0] - 900 * 2.2 / 4.2) < 0.001)
        #expect(widths[1] == 64)
        #expect(abs(widths[2] - 900 / 4.2) < 0.001)
        let tight = T.columnWidths([.flexible(min: 50), .fixed(64)], available: 80, gap: 12)
        #expect(tight[0] == 50)
    }

    @Test func columnWidthsPinSeveralMinimumsAndRedistribute() {
        // 400 − 4·10 − 60 = 300 flexible; equal shares would be 75. The 120-min and 100-min columns pin,
        // leaving 300 − 120 − 100 = 80 for the other two (40 each).
        let w = T.columnWidths([.flexible(min: 120), .flexible(min: 0), .fixed(60), .flexible(min: 100), .flexible(min: 0)],
                               available: 400, gap: 10)
        #expect(w == [120, 40, 60, 100, 40])
        // A weighted column that pins frees its share for the others.
        let f = T.columnWidths([.fraction(3, min: 0), .fraction(1, min: 200), .flexible(min: 0)], available: 424, gap: 12)
        // 400 flexible; share of col1 = 80 < 200 → pinned; remaining 200 over weights 3 + 1 → 150, 50.
        #expect(f == [150, 200, 50])
    }

    @Test func rowMenuModel() {
        let mine = ProcessTarget.process(pid: 2210, name: "Final Cut Pro", path: "/Applications/Final Cut Pro.app", uid: 501)
        let m1 = TTRowActionsMenu.model(target: mine, canControl: true, hasForceQuitHandler: true, ownPID: 1, ownBundleID: nil)
        #expect(m1 == .init(ownerHeader: nil, quitEnabled: true, forceQuitVisible: true, forceQuitEnabled: true,
                            revealEnabled: true, quitsTelltale: false))
        let root = ProcessTarget.process(pid: 412, name: "WindowServer", path: nil, uid: 88)
        let m2 = TTRowActionsMenu.model(target: root, canControl: false, hasForceQuitHandler: true, ownPID: 1, ownBundleID: nil,
                                        userName: { _ in "_windowserver" })
        #expect(m2.ownerHeader == "Owned by _windowserver")
        #expect(!m2.quitEnabled && !m2.forceQuitEnabled && m2.forceQuitVisible && !m2.revealEnabled)
        let me = ProcessTarget.app(AppIdentity(key: AppKey(kind: .app, id: "dev.telltale.Telltale"), displayName: "Telltale"),
                                   pids: [77])
        let m3 = TTRowActionsMenu.model(target: me, canControl: true, hasForceQuitHandler: true, ownPID: 77, ownBundleID: nil)
        #expect(m3.quitsTelltale && m3.quitEnabled && !m3.forceQuitVisible)
        let rootApp = ProcessTarget.app(AppIdentity(key: AppKey(kind: .process, id: "/usr/sbin/mds"), displayName: "mds"),
                                        pids: [300])
        let m4 = TTRowActionsMenu.model(target: rootApp, canControl: false, hasForceQuitHandler: true, ownPID: 1, ownBundleID: nil)
        #expect(m4.ownerHeader == "Owned by another user")
        #expect(!m4.quitEnabled && !m4.forceQuitEnabled && m4.forceQuitVisible && !m4.revealEnabled && !m4.quitsTelltale)
        // No confirm handler → Force Quit disabled (it must always confirm).
        #expect(!TTRowActionsMenu.model(target: mine, canControl: true, hasForceQuitHandler: false, ownPID: 1,
                                        ownBundleID: nil).forceQuitEnabled)
    }

    @MainActor @Test func rowActionsButtonIsA24ptHitTargetWithTheNativeMenu() {
        let target = ProcessTarget.process(pid: 412, name: "WindowServer", path: nil, uid: 88)
        let host = NSHostingView(rootView: TTRowActionsButton(target: target, name: "WindowServer"))
        #expect(host.fittingSize == CGSize(width: 24, height: 24))
        let menu = TTRowActionsMenu.nsMenu(target: target, actions: ProcessActions(canControl: { _ in false }),
                                           commands: .noop, requestForceQuit: { _ in }, onResult: nil)
        #expect(menu.items.first?.title.hasPrefix("Owned by ") == true)
        let rest = Array(menu.items.dropFirst())
        #expect(rest.map(\.title) == ["Quit", "Force Quit…", "", "Reveal in Finder", "Open in Activity Monitor"])
        #expect(rest.map(\.isEnabled) == [false, false, false, false, true]) // separator reports disabled
        let mine = TTRowActionsMenu.nsMenu(target: .process(pid: 2210, name: "FCP", path: "/Applications/FCP.app", uid: 501),
                                           actions: ProcessActions(canControl: { _ in true }), commands: .noop,
                                           requestForceQuit: { _ in }, onResult: nil)
        #expect(mine.items.map(\.title) == ["Quit", "Force Quit…", "", "Reveal in Finder", "Open in Activity Monitor"])
        let enabled = mine.items.filter { !$0.isSeparatorItem }.map(\.isEnabled)
        #expect(enabled == [true, true, true, true])
    }

    @Test func nextSelectionMovesWithArrows() {
        let ids = ["a", "b", "c"]
        #expect(T.moved(selection: nil, in: ids, by: 1) == "a")
        #expect(T.moved(selection: "a", in: ids, by: 1) == "b")
        #expect(T.moved(selection: "c", in: ids, by: 1) == "c")
        #expect(T.moved(selection: "a", in: ids, by: -1) == "a")
        #expect(T.moved(selection: "zz", in: ids, by: -1) == "c")
    }
}
