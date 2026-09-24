import AppKit
@testable import MonitorScreens
import Testing

@Suite("Hot key spec")
struct HotKeySpecTests {
    @Test func defaultIsOptionZ() {
        #expect(HotKeySpec.defaultOverlay == HotKeySpec(keyCode: 6, modifiers: 2048))
        #expect(HotKeySpec.defaultOverlay.isValid)
        #expect(HotKeySpec.defaultOverlay.display == "⌥Z")
    }

    @Test func fromOptionZ() {
        let spec = HotKeySpec.from(keyCode: 6, modifierFlags: NSEvent.ModifierFlags.option.rawValue)
        #expect(spec == .defaultOverlay)
        #expect(spec?.display == "⌥Z")
    }

    @Test func shiftOnlyIsInvalid() {
        #expect(HotKeySpec.from(keyCode: 6, modifierFlags: NSEvent.ModifierFlags.shift.rawValue) == nil)
        #expect(HotKeySpec.from(keyCode: 6, modifierFlags: 0) == nil)
        #expect(!HotKeySpec(keyCode: 6, modifiers: 512).isValid)
    }

    @Test func allModifiersDisplayInCanonicalOrder() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let spec = HotKeySpec.from(keyCode: 6, modifierFlags: flags.rawValue)
        #expect(spec == HotKeySpec(keyCode: 6, modifiers: 256 | 512 | 2048 | 4096))
        #expect(spec?.display == "⌃⌥⇧⌘Z")
    }

    @Test func ignoresNonModifierFlagBits() {
        let flags: NSEvent.ModifierFlags = [.command, .capsLock, .numericPad, .function]
        #expect(HotKeySpec.from(keyCode: 11, modifierFlags: flags.rawValue) == HotKeySpec(keyCode: 11, modifiers: 256))
    }

    /// ⌘-only standard shortcuts (⌘C, ⌘Q, ⌘, …) belong to every app's menus: never valid as a global hotkey.
    @Test func commandOnlyStandardShortcutsAreReserved() {
        for code: UInt32 in [8, 9, 7, 6, 0, 12, 13, 1, 35, 45, 31, 17, 4, 46, 43] {
            let spec = HotKeySpec(keyCode: code, modifiers: 256)
            #expect(spec.isReserved, "\(spec.display)")
            #expect(!spec.isValid, "\(spec.display)")
        }
        #expect(HotKeySpec.from(keyCode: 8, modifierFlags: NSEvent.ModifierFlags.command.rawValue) == nil)
        #expect(!HotKeySpec(keyCode: 8, modifiers: 256 | 512).isReserved)       // ⌘⇧C is fine
        #expect(!HotKeySpec(keyCode: 8, modifiers: 2048).isReserved)            // ⌥C is fine
        #expect(!HotKeySpec(keyCode: 11, modifiers: 256).isReserved)            // ⌘B is fine
    }

    @Test func keypadSectionAndHelpNames() {
        #expect(HotKeySpec(keyCode: 82, modifiers: 2048).display == "⌥Keypad 0")
        #expect(HotKeySpec(keyCode: 92, modifiers: 2048).display == "⌥Keypad 9")
        #expect(HotKeySpec(keyCode: 65, modifiers: 2048).display == "⌥Keypad .")
        #expect(HotKeySpec(keyCode: 76, modifiers: 2048).display == "⌥Keypad ⌤")
        #expect(HotKeySpec(keyCode: 10, modifiers: 2048).display == "⌥§")
        #expect(HotKeySpec(keyCode: 114, modifiers: 2048).display == "⌥Help")
    }

    @Test func keyNames() {
        #expect(HotKeySpec(keyCode: 0, modifiers: 256).display == "⌘A")
        #expect(HotKeySpec(keyCode: 29, modifiers: 4096).display == "⌃0")
        #expect(HotKeySpec(keyCode: 49, modifiers: 2048).display == "⌥Space")
        #expect(HotKeySpec(keyCode: 122, modifiers: 256).display == "⌘F1")
        #expect(HotKeySpec(keyCode: 250, modifiers: 256).display == "⌘#250")
    }
}
