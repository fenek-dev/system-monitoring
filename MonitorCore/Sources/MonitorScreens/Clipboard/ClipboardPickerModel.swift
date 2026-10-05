import AppKit
import ClipboardCore
import Observation

/// What a key press does in the clipboard picker (spec 2026-10-06 clipboard history, "Picker" key table).
public enum ClipboardPickerCommand: Equatable, Sendable {
    case moveUp, moveDown, pasteSelected
    /// ⌘1…⌘9: the nth visible row.
    case quickPaste(Int)
    case togglePin, deleteSelected, escape
}

public enum ClipboardPickerKey {
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]   // 1…9 on the ANSI top row

    /// `NSEvent.keyCode` / `modifierFlags.rawValue` → command; nil = leave the event to the search field (plain
    /// typing, plain ⌫, ⌘A/⌘C/⌘V/⌘X/⌘Z …). Only ⌘⌥⌃⇧ are compared: caps lock and the numpad/function bits that
    /// arrow keys carry are ignored.
    public static func command(keyCode: UInt16, modifierFlags: UInt) -> ClipboardPickerCommand? {
        let flags = NSEvent.ModifierFlags(rawValue: modifierFlags).intersection([.command, .option, .control, .shift])
        if flags.isDisjoint(with: [.command, .option, .control]) {
            switch keyCode {
            case 126: return .moveUp
            case 125: return .moveDown
            case 36, 76: return .pasteSelected                    // Return, keypad Enter
            case 53: return .escape
            default: return nil
            }
        }
        guard flags == .command else { return nil }
        switch keyCode {
        case 35: return .togglePin
        case 51: return .deleteSelected
        default: return digitKeyCodes.firstIndex(of: keyCode).map { .quickPaste($0 + 1) }
        }
    }
}

/// State of the clipboard picker. The App owns the items (store) and re-publishes them after pin/delete; the model
/// owns the query and the selection. Key events reach it through `handle` (the panel maps them with
/// `ClipboardPickerKey`), never through the view.
@MainActor @Observable public final class ClipboardPickerModel {
    public struct Actions: Sendable {
        public var paste: @MainActor (ClipItem) -> Void
        public var setPinned: @MainActor (ClipItem, Bool) -> Void
        public var delete: @MainActor (ClipItem) -> Void
        public var close: @MainActor () -> Void
        public var openAccessibilitySettings: @MainActor () -> Void

        public init(paste: @escaping @MainActor (ClipItem) -> Void = { _ in },
                    setPinned: @escaping @MainActor (ClipItem, Bool) -> Void = { _, _ in },
                    delete: @escaping @MainActor (ClipItem) -> Void = { _ in },
                    close: @escaping @MainActor () -> Void = {},
                    openAccessibilitySettings: @escaping @MainActor () -> Void = {}) {
            self.paste = paste
            self.setPinned = setPinned
            self.delete = delete
            self.close = close
            self.openAccessibilitySettings = openAccessibilitySettings
        }

        public static let noop = Actions()
    }

    /// Assigning keeps the selection while its item is still visible, else selects the first row.
    public var items: [ClipItem] {
        didSet { if !isVisible(selection) { selection = rows.first?.id } }
    }

    /// Changing it selects the first row of the new result.
    public var query = "" {
        didSet { if query != oldValue { selection = rows.first?.id } }
    }

    public var needsAccessibility: Bool
    public var now: Date
    @ObservationIgnored public var actions: Actions
    public let thumbnail: @MainActor (ClipItem) -> NSImage?
    public private(set) var selection: Int64?
    /// Bumped by `reset` (every open): the view takes keyboard focus again, also when its panel is reused.
    public private(set) var focusToken = 0

    public init(items: [ClipItem] = [], now: Date = Date(), needsAccessibility: Bool = false,
                actions: Actions = .noop, thumbnail: @escaping @MainActor (ClipItem) -> NSImage? = { _ in nil }) {
        self.items = items
        self.now = now
        self.needsAccessibility = needsAccessibility
        self.actions = actions
        self.thumbnail = thumbnail
        selection = Self.order(items).first?.id
    }

    /// Whitespace never filters (the matcher ignores it), so a blank query still shows the sections.
    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Empty query: the "Pinned" section, then "Recent". With a query: the matches only.
    public var pinnedRows: [ClipItem] { isSearching ? [] : Self.order(items).filter(\.pinned) }
    public var recentRows: [ClipItem] { isSearching ? rankedRows : Self.order(items).filter { !$0.pinned } }

    /// Visible order: pinned then recent, or ranked while searching (best match first, then recency).
    public var rows: [ClipItem] { pinnedRows + recentRows }

    /// Called when the picker opens: clears the query and selects the first row.
    public func reset(items: [ClipItem], now: Date) {
        query = ""
        self.now = now
        self.items = items
        selection = rows.first?.id
        focusToken += 1
    }

    public func select(_ id: Int64) {
        if isVisible(id) { selection = id }
    }

    /// Returns true when the command is consumed. With no rows everything but `escape` is consumed and ignored.
    @discardableResult public func handle(_ command: ClipboardPickerCommand) -> Bool {
        if command == .escape {
            if query.isEmpty { actions.close() } else { query = "" }
            return true
        }
        let rows = rows
        guard !rows.isEmpty else { return true }
        let index = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        switch command {
        case .moveUp:
            selection = rows[index.map { max($0 - 1, 0) } ?? 0].id
        case .moveDown:
            selection = rows[index.map { min($0 + 1, rows.count - 1) } ?? 0].id
        case .pasteSelected:
            if let index { actions.paste(rows[index]) }
        case .quickPaste(let n):
            if rows.indices.contains(n - 1) { actions.paste(rows[n - 1]) }
        case .togglePin:
            if let index { actions.setPinned(rows[index], !rows[index].pinned) }
        case .deleteSelected:
            if let index { delete(rows[index]) }
        case .escape:
            break
        }
        return true
    }

    /// Removes the item at once (the App re-publishes `items` after the store confirms) and moves the selection to
    /// the row that took its place, else the previous one. A delete button on an unselected row keeps the selection.
    public func delete(_ item: ClipItem) {
        let index = rows.firstIndex { $0.id == item.id }
        let wasSelected = selection == item.id
        actions.delete(item)
        items.removeAll { $0.id == item.id }
        guard wasSelected, let index else { return }
        let remaining = rows
        selection = remaining.indices.contains(index) ? remaining[index].id : remaining.last?.id
    }

    private var rankedRows: [ClipItem] { FuzzyMatcher.rank(Self.order(items), query: query) }

    private func isVisible(_ id: Int64?) -> Bool {
        guard let id else { return false }
        return rows.contains { $0.id == id }
    }

    /// Store order: pinned first, then `lastUsedAt` descending (ties by id, newest first).
    private static func order(_ items: [ClipItem]) -> [ClipItem] {
        items.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
            return $0.id > $1.id
        }
    }
}
