import AppKit
import ClipboardCore
import Foundation
@testable import MonitorScreens
import Testing

/// Clipboard picker logic (spec 2026-10-06 clipboard history, "Picker" and "Tests"): model, key map, placement.
@Suite("ClipboardPickerTests") @MainActor
struct ClipboardPickerTests {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    /// Text item `id` last used `id` minutes ago, so a higher id is older.
    private func item(_ id: Int64, _ text: String = "", source: String? = nil, pinned: Bool = false) -> ClipItem {
        ClipItem(id: id, kind: .text, text: text.isEmpty ? "item \(id)" : text, sourceName: source,
                 lastUsedAt: now.addingTimeInterval(-Double(id) * 60), pinned: pinned)
    }

    private final class Log {
        var pasted: [Int64] = []
        var pinned: [(Int64, Bool)] = []
        var deleted: [Int64] = []
        var closed = 0
    }

    private func model(_ items: [ClipItem]) -> (ClipboardPickerModel, Log) {
        let log = Log()
        let actions = ClipboardPickerModel.Actions(
            paste: { log.pasted.append($0.id) }, setPinned: { log.pinned.append(($0.id, $1)) },
            delete: { log.deleted.append($0.id) }, close: { log.closed += 1 })
        return (ClipboardPickerModel(items: items, now: now, actions: actions), log)
    }

    // MARK: Selection

    /// Bug: ↑ at the top or ↓ at the bottom wrapped or left the list.
    @Test func selectionStopsAtBothEnds() {
        let (m, _) = model([item(1), item(2), item(3)])
        #expect(m.selection == 1)
        m.handle(.moveUp)
        #expect(m.selection == 1)
        m.handle(.moveDown)
        m.handle(.moveDown)
        m.handle(.moveDown)
        #expect(m.selection == 3)
    }

    /// Bug: after typing, the selection stayed on a row that moved or vanished.
    @Test func queryChangeSelectsFirstRow() {
        let (m, _) = model([item(1, "alpha"), item(2, "beta"), item(3, "gamma")])
        m.handle(.moveDown)
        m.handle(.moveDown)
        #expect(m.selection == 3)
        m.query = "bet"
        #expect(m.rows.map(\.id) == [2])
        #expect(m.selection == 2)
    }

    /// Bug: ⌘n pasted the nth item of the whole history instead of the nth visible row (pinned first, or ranked
    /// while searching), and n past the end crashed or pasted something.
    @Test func quickPasteUsesVisibleRows() {
        let (m, log) = model([item(1), item(2), item(3, pinned: true)])
        m.handle(.quickPaste(1))                                  // pinned row comes first
        m.handle(.quickPaste(3))
        m.handle(.quickPaste(4))                                  // beyond the rows: nothing
        m.handle(.quickPaste(0))
        #expect(log.pasted == [3, 2])
        m.query = "item 2"
        m.handle(.quickPaste(1))
        #expect(log.pasted == [3, 2, 2])
    }

    /// Bug: deleting the last row left no selection (or an index past the end); deleting a middle row selected
    /// the first row.
    @Test func deleteMovesSelectionToNeighbour() {
        let (m, log) = model([item(1), item(2), item(3)])
        m.select(2)
        m.handle(.deleteSelected)
        #expect(m.rows.map(\.id) == [1, 3])
        #expect(m.selection == 3)                                 // the row that took its place
        m.handle(.deleteSelected)
        #expect(m.selection == 1)                                 // last row gone: the previous one
        #expect(log.deleted == [2, 3])
    }

    /// Bug: the re-published list (after pin/delete in the store) reset the selection to the top.
    @Test func republishingKeepsSelectionWhileVisible() {
        let (m, _) = model([item(1), item(2), item(3)])
        m.select(2)
        m.items = [item(1), item(2, pinned: true), item(3)]
        #expect(m.selection == 2)
        m.items = [item(1), item(3)]
        #expect(m.selection == 1)
    }

    /// Bug: Esc closed the picker while a query was typed, or only cleared it when the second Esc was due.
    @Test func escapeClearsQueryThenCloses() {
        let (m, log) = model([item(1, "alpha")])
        m.query = "alp"
        #expect(m.handle(.escape))
        #expect(m.query.isEmpty)
        #expect(log.closed == 0)
        m.handle(.escape)
        #expect(log.closed == 1)
    }

    /// Bug: commands on an empty list crashed (index out of range); Esc must still work there.
    @Test func emptyListConsumesCommandsAndEscapeStillCloses() {
        let (m, log) = model([])
        for command in [ClipboardPickerCommand.moveUp, .moveDown, .pasteSelected, .quickPaste(1), .togglePin,
                        .deleteSelected] {
            #expect(m.handle(command))
        }
        #expect(log.pasted.isEmpty && log.pinned.isEmpty && log.deleted.isEmpty && log.closed == 0)
        m.handle(.escape)
        #expect(log.closed == 1)
    }

    @Test func togglePinFlipsTheSelectedItem() {
        let (m, log) = model([item(1), item(2, pinned: true)])
        m.handle(.togglePin)                                      // the pinned row is first
        m.handle(.moveDown)
        m.handle(.togglePin)
        #expect(log.pinned.map(\.0) == [2, 1])
        #expect(log.pinned.map(\.1) == [false, true])
    }

    // MARK: Key map

    /// Bug: ⌘⌫ must delete while plain ⌫ stays with the search field; caps lock / numpad / function bits (carried
    /// by arrow keys) must not hide a command; ⌘C/⌘V/⌘A/⌘Z stay with the field.
    @Test func mapsKeys() {
        struct Case {
            var code: UInt16
            var flags: NSEvent.ModifierFlags
            var expected: ClipboardPickerCommand?
        }
        let cases: [Case] = [
            Case(code: 126, flags: [.numericPad, .function], expected: .moveUp),
            Case(code: 125, flags: [.numericPad, .function, .capsLock], expected: .moveDown),
            Case(code: 36, flags: [], expected: .pasteSelected),
            Case(code: 76, flags: [], expected: .pasteSelected),
            Case(code: 36, flags: [.shift], expected: .pasteSelected),
            Case(code: 53, flags: [], expected: .escape),
            Case(code: 35, flags: [.command], expected: .togglePin),
            Case(code: 51, flags: [.command], expected: .deleteSelected),
            Case(code: 51, flags: [.command, .capsLock], expected: .deleteSelected),
            Case(code: 18, flags: [.command], expected: .quickPaste(1)),
            Case(code: 23, flags: [.command], expected: .quickPaste(5)),
            Case(code: 25, flags: [.command], expected: .quickPaste(9)),
            Case(code: 51, flags: [], expected: nil),
            Case(code: 51, flags: [.shift], expected: nil),
            Case(code: 0, flags: [], expected: nil),
            Case(code: 35, flags: [], expected: nil),
            Case(code: 35, flags: [.command, .shift], expected: nil),
            Case(code: 18, flags: [], expected: nil),
            Case(code: 18, flags: [.option], expected: nil),
            Case(code: 8, flags: [.command], expected: nil),
            Case(code: 9, flags: [.command], expected: nil),
            Case(code: 0, flags: [.command], expected: nil),
            Case(code: 6, flags: [.command], expected: nil),
            Case(code: 7, flags: [.command], expected: nil),
            Case(code: 126, flags: [.command], expected: nil),
            Case(code: 36, flags: [.command], expected: nil),
        ]
        for c in cases {
            #expect(ClipboardPickerKey.command(keyCode: c.code, modifierFlags: c.flags.rawValue) == c.expected,
                    "key \(c.code) flags \(c.flags.rawValue)")
        }
    }

    // MARK: Placement

    /// Bug: the panel hung off a screen edge when opened near a corner.
    @Test func placementStaysInsideVisibleFrame() {
        let screen = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let size = CGSize(width: 420, height: 460)
        // (mouse, expected origin). Normal: top-left 8 right of and below the mouse.
        let cases: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 600, y: 600), CGPoint(x: 608, y: 132)),     // centre
            (CGPoint(x: 105, y: 845), CGPoint(x: 113, y: 377)),     // top-left: fits as is
            (CGPoint(x: 1095, y: 845), CGPoint(x: 680, y: 377)),    // top-right: shifted left
            (CGPoint(x: 105, y: 55), CGPoint(x: 113, y: 50)),       // bottom-left: shifted up
            (CGPoint(x: 1095, y: 55), CGPoint(x: 680, y: 50)),      // bottom-right: both
        ]
        for (mouse, origin) in cases {
            let frame = ClipboardPanelPlacement.frame(mouse: mouse, size: size, visibleFrame: screen)
            #expect(frame == CGRect(origin: origin, size: size), "mouse \(mouse)")
            #expect(screen.contains(frame))
        }
    }

    @Test func placementPinsOversizedPanelToTopLeft() {
        let screen = CGRect(x: 0, y: 0, width: 300, height: 300)
        let frame = ClipboardPanelPlacement.frame(mouse: CGPoint(x: 150, y: 150),
                                                  size: CGSize(width: 420, height: 460), visibleFrame: screen)
        #expect(frame.minX == 0)
        #expect(frame.maxY == 300)
    }

    // MARK: Age text

    /// Bug: unit boundaries off by one ("60m", "24h"), or a negative interval printing a minus sign.
    @Test func ageText() {
        let cases: [(seconds: Double, expected: String)] = [
            (-5, "now"), (59, "now"), (60, "1m"), (3_599, "59m"), (3_600, "1h"), (86_399, "23h"), (86_400, "1d"),
            (9 * 86_400, "9d"),
        ]
        for c in cases {
            #expect(ClipboardPickerView.ageText(since: now.addingTimeInterval(-c.seconds), now: now) == c.expected,
                    "\(c.seconds) s")
        }
    }
}

/// Settings for the clipboard history (spec "Settings").
@Suite("ClipboardSettingsTests") @MainActor
struct ClipboardSettingsTests {
    /// Bug: a stored clipboard shortcut that is invalid (shift only, or ⌘C reserved) registered anyway, or a
    /// missing one left the feature without a hotkey.
    @Test func invalidStoredClipboardHotKeyFallsBackToDefault() {
        let (_, d) = ScreenFixture.settings()
        #expect(SettingsStore(defaults: d).clipboardHotKey == .defaultClipboard)
        d.set(["keyCode": 9, "modifiers": 512], forKey: SettingsStore.Key.clipboardHotKey)       // ⇧V
        #expect(SettingsStore(defaults: d).clipboardHotKey == .defaultClipboard)
        d.set(["keyCode": 8, "modifiers": 256], forKey: SettingsStore.Key.clipboardHotKey)       // ⌘C
        #expect(SettingsStore(defaults: d).clipboardHotKey == .defaultClipboard)
    }

    /// Bug: the two shortcuts shared a key, or the overlay load changed with the refactor.
    @Test func hotKeysPersistIndependently() {
        let (s, d) = ScreenFixture.settings()
        #expect(s.overlayHotKey == .defaultOverlay)
        #expect(HotKeySpec.defaultClipboard == HotKeySpec(keyCode: 9, modifiers: 768))
        s.clipboardHotKey = HotKeySpec(keyCode: 11, modifiers: 256 | 2048)
        let again = SettingsStore(defaults: d)
        #expect(again.clipboardHotKey == HotKeySpec(keyCode: 11, modifiers: 256 | 2048))
        #expect(again.overlayHotKey == .defaultOverlay)
        d.set(["keyCode": 31, "modifiers": 4096], forKey: SettingsStore.Key.overlayHotKey)
        #expect(SettingsStore(defaults: d).overlayHotKey == HotKeySpec(keyCode: 31, modifiers: 4096))
        #expect(SettingsStore(defaults: d).clipboardHotKey == HotKeySpec(keyCode: 11, modifiers: 256 | 2048))
    }

    @Test func clipboardIsOnByDefaultAndPersists() {
        let (s, d) = ScreenFixture.settings()
        #expect(s.clipboardEnabled)
        s.clipboardEnabled = false
        #expect(!SettingsStore(defaults: d).clipboardEnabled)
    }
}
