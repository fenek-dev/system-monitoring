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
        #expect(HotKeySpec.from(keyCode: 0, modifierFlags: flags.rawValue) == HotKeySpec(keyCode: 0, modifiers: 256))
    }

    @Test func keyNames() {
        #expect(HotKeySpec(keyCode: 0, modifiers: 256).display == "⌘A")
        #expect(HotKeySpec(keyCode: 29, modifiers: 4096).display == "⌃0")
        #expect(HotKeySpec(keyCode: 49, modifiers: 2048).display == "⌥Space")
        #expect(HotKeySpec(keyCode: 122, modifiers: 256).display == "⌘F1")
        #expect(HotKeySpec(keyCode: 250, modifiers: 256).display == "⌘#250")
    }
}
