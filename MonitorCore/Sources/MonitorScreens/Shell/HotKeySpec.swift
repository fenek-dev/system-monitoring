import AppKit

/// A global shortcut in Carbon terms (spec 2026-09-25 overlay, "Hotkey"): the App registers it with
/// `RegisterEventHotKey`, which takes a Carbon virtual key code and a Carbon modifier mask.
public struct HotKeySpec: Equatable, Codable, Sendable {
    /// Carbon virtual key (`kVK_ANSI_Z` = 6).
    public var keyCode: UInt32
    /// Carbon mask: `cmdKey` 256, `shiftKey` 512, `optionKey` 2048, `controlKey` 4096.
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let cmdKey: UInt32 = 256
    public static let shiftKey: UInt32 = 512
    public static let optionKey: UInt32 = 2048
    public static let controlKey: UInt32 = 4096

    public static let defaultOverlay = HotKeySpec(keyCode: 6, modifiers: 2048)   // ⌥Z

    /// At least one of ⌘, ⌥, ⌃: a shift-only or bare key would swallow ordinary typing.
    public var isValid: Bool { modifiers & (Self.cmdKey | Self.optionKey | Self.controlKey) != 0 }

    /// Modifier glyphs in the menu order ⌃⌥⇧⌘, then the key name ("⌥Z").
    public var display: String {
        var s = ""
        if modifiers & Self.controlKey != 0 { s += "⌃" }
        if modifiers & Self.optionKey != 0 { s += "⌥" }
        if modifiers & Self.shiftKey != 0 { s += "⇧" }
        if modifiers & Self.cmdKey != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// From an `NSEvent` key code and `NSEvent.ModifierFlags` raw value; nil if the combination is invalid.
    public static func from(keyCode: UInt16, modifierFlags: UInt) -> HotKeySpec? {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags)
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }
        if flags.contains(.shift) { mask |= shiftKey }
        let spec = HotKeySpec(keyCode: UInt32(keyCode), modifiers: mask)
        return spec.isValid ? spec : nil
    }

    /// US-ANSI names for Carbon virtual key codes (`Events.h`); anything else shows as "#code".
    static func keyName(_ code: UInt32) -> String {
        if let name = keyNames[code] { return name }
        return "#\(code)"
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I",
        35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
