# Clipboard history — implementation plan

Spec: `docs/superpowers/specs/2026-10-06-clipboard-history-design.md`. Progress: `clipboard-progress.md` (this dir).

Three tasks, run one after another in the same checkout (B needs A's types, C needs B's model). Each task owns
the files listed and edits nothing else. The public APIs below are the contract between tasks: keep the names and
signatures; add members if needed.

Rules for every task:
- Swift 6 language mode, strict concurrency. No `@unchecked`, no `&-`, no `as any`, no lint disables
  (`scripts/ci.sh` greps for the first two).
- Tests use Swift Testing (`import Testing`), as the existing suites do. One test per behaviour, exact assertions,
  no sleeps or real clock (pass `now`). For each core behaviour, break the code once, see the test fail, revert.
- Run only your suites: `scripts/test.sh <Suite> …`. Output over ~100 lines goes through `grep`/`tail`.
- Do not commit. Finish with a report of at most 15 lines: files, test results quoted, anything not verified.

## Task A — `ClipboardCore` and `ClipboardStore`
Owns: `MonitorCore/Package.swift`, `MonitorCore/Sources/ClipboardCore/`, `MonitorCore/Sources/ClipboardStore/`,
`MonitorCore/Tests/ClipboardCoreTests/`, `MonitorCore/Tests/ClipboardStoreTests/`.

`Package.swift`:
- targets `ClipboardCore` (no dependencies) and `ClipboardStore` (`ClipboardCore`, GRDB), both as library
  products; test targets `ClipboardCoreTests`, `ClipboardStoreTests`.
- add `ClipboardCore` to the dependencies of `MonitorScreens` and `MonitorScreensTests`.

`ClipboardCore` (Foundation + CryptoKit only):
```swift
public enum ClipKind: String, Sendable, Codable, CaseIterable { case text, image, files }

public struct ClipItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var kind: ClipKind
    public var text: String            // text items: first `ClipboardPolicy.previewCharacters` characters; else ""
    public var textLength: Int         // full character count of a text item; else 0
    public var files: [String]         // absolute paths
    public var imageFile: String?      // file names inside the store's images directory
    public var thumbFile: String?
    public var imageWidth: Int         // pixels; 0 unless image
    public var imageHeight: Int
    public var byteSize: Int64         // text UTF-8 bytes, PNG file bytes, 0 for files
    public var hash: String
    public var sourceBundleID: String?
    public var sourceName: String?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var pinned: Bool
    public init(…)                     // memberwise, defaults for everything except id and kind
    public var preview: String         // spec "Preview"
    public var searchText: String      // text prefix, or file names, plus nothing else
}

public struct ClipSource: Equatable, Sendable { public var bundleID: String?; public var name: String? }

public struct ClipCapture: Equatable, Sendable {
    public enum Content: Equatable, Sendable { case text(String), image(Data), files([String]) }
    public var content: Content
    public var source: ClipSource
    public var hash: String { get }    // SHA-256 hex, spec "Data"
}

public struct ClipboardPolicy: Equatable, Sendable {
    public var maxItems = 500
    public var maxAge: TimeInterval = 30 * 86_400
    public var maxImageBytes = 20 * 1_048_576
    public var maxTotalImageBytes: Int64 = 500 * 1_048_576
    public var maxTextBytes = 2 * 1_048_576
    public var previewCharacters = 2_000
    public var thumbnailPixels = 128
    public static let `default`
}

public struct PasteboardSnapshot: Equatable, Sendable {
    public var types: Set<String>      // pasteboard type identifiers
    public var filePaths: [String]
    public var string: String?
    public var imageData: Data?        // public.png, else public.tiff
}

public enum PasteboardClassifier {
    public static let ownMarkerType = "dev.warden.clipboard.own"
    public enum Skip: Equatable, Sendable { case concealed, ownWrite, empty, tooLarge }
    public enum Outcome: Equatable, Sendable { case capture(ClipCapture.Content), skip(Skip) }
    public static func classify(_ snapshot: PasteboardSnapshot, policy: ClipboardPolicy = .default) -> Outcome
}

public enum FuzzyMatcher {
    /// nil = `query` is not a subsequence of `text`. Case- and diacritic-insensitive. Higher is better:
    /// contiguous runs and word starts score above scattered characters.
    public static func score(query: String, in text: String) -> Int?
    /// Empty query → `items` unchanged. Otherwise items matching in `searchText` or `sourceName`, best first,
    /// ties by `lastUsedAt` descending.
    public static func rank(_ items: [ClipItem], query: String) -> [ClipItem]
}
```

`ClipboardStore` (GRDB + ImageIO; no AppKit):
```swift
public actor ClipboardStore {
    public enum Location: Sendable {
        case directory(URL)                      // <dir>/clipboard.sqlite, <dir>/images/
        case inMemory(imagesDirectory: URL)
    }
    public struct Stats: Equatable, Sendable { public var itemCount: Int; public var byteSize: Int64 }
    public nonisolated let imagesDirectory: URL
    public init(location: Location, policy: ClipboardPolicy = .default, now: Date) throws
    @discardableResult public func record(_ capture: ClipCapture, at now: Date) throws -> ClipItem?  // nil: undecodable image
    public func items() throws -> [ClipItem]     // pinned first, then lastUsedAt descending
    public func fullText(_ id: Int64) throws -> String?
    public func imageData(_ id: Int64) throws -> Data?     // PNG
    public func touch(_ id: Int64, at now: Date) throws
    public func setPinned(_ id: Int64, _ pinned: Bool) throws
    public func delete(_ id: Int64) throws
    public func clearUnpinned() throws
    public func stats() throws -> Stats          // byteSize = text bytes + image and thumbnail file bytes
}
```
Follow `MonitorStore/Database.swift` for pragmas and the corrupt-file move-aside, `Schema.swift` for the migrator.

Tests: spec "Tests", the first four bullets. Images for tests are drawn in the test (CGContext + ImageIO).
Accept: `scripts/test.sh ClipboardCoreTests ClipboardStoreTests` passes; `swift build --build-tests` in
`MonitorCore` has no errors and no new warnings.

## Task B — picker UI and settings (`MonitorScreens`)
Owns: `MonitorCore/Sources/MonitorScreens/Clipboard/` (new), `Shell/SettingsStore.swift`, `Shell/SettingsView.swift`,
`Shell/HotKeyRecorder.swift`, `Shell/HotKeySpec.swift`, `Shell/ShellEnvironment.swift`, `Shell/LaunchOptions.swift`,
`Shell/ScreenCatalog.swift`, `MonitorUIKit/Tokens/TTIcon.swift` (new icons only), `docs/design/DESIGN.md` (new
§3.18 only), tests in `MonitorCore/Tests/MonitorScreensTests/` (and the icon/gallery goldens if a new icon changes
them).

Settings:
- `HotKeySpec.defaultClipboard` = ⌘⇧V (key code 9, modifiers 768).
- `SettingsStore`: `clipboardEnabled` (`clipboard.enabled`, default true), `clipboardHotKey` (`clipboard.hotkey`,
  invalid → default), and
  ```swift
  public struct ClipboardStatus: Equatable, Sendable {
      public var needsAccessibility: Bool; public var itemCount: Int; public var byteSize: Int64
  }
  @ObservationIgnored public var refreshClipboardStatus: (@MainActor () -> ClipboardStatus)?   // nil in renders
  @ObservationIgnored public var clearClipboardHistory: (@MainActor () -> Void)?
  ```
- `HotKeyState.clipboardStatus: HotKeyStatus` and `EnvironmentValues.clipboardHotKeyStatus`, injected in
  `ShellEnvironment` next to `overlayHotKeyStatus`.
- `HotKeyRecorder(spec:label:)`: `label` replaces the hard-coded accessibility label "Overlay shortcut"
  (`Shell/HotKeyRecorder.swift:92`); default keeps the old text.
- `SettingsView`: section "Clipboard" after "Overlay", rows as in spec "Settings". Status is polled every 1 s
  while the switch is on, like `pollExtraDim` (`Shell/SettingsView.swift:219`).
- `LaunchOptions.openClipboard` (`--open-clipboard`).

Picker:
```swift
public enum ClipboardPickerCommand: Equatable, Sendable {
    case moveUp, moveDown, pasteSelected, quickPaste(Int)   // 1…9
    case togglePin, deleteSelected, escape
}
public enum ClipboardPickerKey {
    /// `NSEvent.keyCode` / `modifierFlags.rawValue` → command; nil = leave the event to the search field.
    public static func command(keyCode: UInt16, modifierFlags: UInt) -> ClipboardPickerCommand?
}
@MainActor @Observable public final class ClipboardPickerModel {
    public struct Actions {
        public var paste: @MainActor (ClipItem) -> Void
        public var setPinned: @MainActor (ClipItem, Bool) -> Void
        public var delete: @MainActor (ClipItem) -> Void
        public var close: @MainActor () -> Void
        public var openAccessibilitySettings: @MainActor () -> Void
        public static let noop: Actions
    }
    public init(items: [ClipItem] = [], now: Date = Date(), needsAccessibility: Bool = false,
                actions: Actions = .noop, thumbnail: @escaping @MainActor (ClipItem) -> NSImage? = { _ in nil })
    public var items: [ClipItem]          // assigning keeps the selection when its item is still visible
    public var query: String              // changing it selects the first row
    public var needsAccessibility: Bool
    public var now: Date
    public var actions: Actions
    public private(set) var selection: Int64?
    public var rows: [ClipItem] { get }   // visible order: pinned then recent, or ranked while searching
    public func reset(items: [ClipItem], now: Date)        // on open: clears the query, selects the first row
    public func select(_ id: Int64)
    @discardableResult public func handle(_ command: ClipboardPickerCommand) -> Bool
}
public struct ClipboardPickerView: View {
    public static let size = CGSize(width: 420, height: 460)
    public init(model: ClipboardPickerModel)
}
public enum ClipboardPanelPlacement {
    public static func frame(mouse: CGPoint, size: CGSize, visibleFrame: CGRect, offset: CGFloat = 8) -> CGRect
}
public enum ClipboardFixture { public static func items(now: Date) -> [ClipItem] }   // renders, tests, `--mock`
```
- The search field takes keyboard focus when the view appears. The view sets no key handlers of its own for the
  commands above: the App's panel maps key events through `ClipboardPickerKey` to `model.handle`.
- The list scrolls to keep the selection visible. Row click pastes; pin and delete buttons call the actions.
- Tokens, fonts, radii and icons come from `MonitorUIKit` (`TTColor`, `TTFont`, `TTSpace`, `TTRadius`, `TTIcon`)
  as `TTPopoverRow` and `TTSearchField` use them. New icons follow DESIGN §1.4. Document the picker as DESIGN
  §3.18 "Clipboard picker (ADDED 2026-10-06)".
- `ScreenCatalog`: `clipboard`, `clipboard-search`, `clipboard-empty`, `clipboard-nomatch`, `clipboard-banner`;
  the `settings` entry grows by the new section.

Tests: spec "Tests" bullets 5–9. Render each new catalog entry with `scripts/render.sh <id>` and look at the PNG.
Accept: the touched suites pass under `scripts/test.sh`; renders reviewed.

## Task C — app wiring (`App/`)
Owns: `App/Sources/Clipboard/` (new), `App/Sources/AppDelegate.swift`, `project.yml`.

- `PasteboardWatcher`: 0.5 s timer on the main run loop; baseline `changeCount` taken at start; builds the
  `PasteboardSnapshot` (reads data only when no skip type is present), classifies, hands captures on.
- `PasteService`: writes an item to the general pasteboard with `PasteboardClassifier.ownMarkerType`; posts ⌘V.
- `ClipboardPanelController`: `PopoverPanel`-style panel hosting `ClipboardPickerView`; key events →
  `ClipboardPickerKey` → `model.handle`; placement through `ClipboardPanelPlacement`; closes on resign key.
- `ClipboardController`: owns the store (`<data dir>/clipboard`, fixtures in memory under `--mock`), watcher,
  panel, its `GlobalHotKey`; follows `settings.clipboardEnabled` and `settings.clipboardHotKey`; publishes
  `env.hotKeyState.clipboardStatus`; sets `settings.refreshClipboardStatus` and `settings.clearClipboardHistory`.
- `AppDelegate`: creates the controller, forwards `setHotKeyRecording`, shuts it down in `closeUI`, honours
  `--open-clipboard`.
- `project.yml`: add `ClipboardCore`, `ClipboardStore` to the package products.

Accept: `scripts/ci.sh ClipboardCoreTests ClipboardStoreTests` plus the suites B touched; app runs.

## Verify (after C)
- Run the Debug build: copy text, an image and a file; open with ⌘⇧V; paste into TextEdit, Terminal and a browser.
- Screenshots of the panel in each state and of Settings.
- Codex review of the whole diff (`gpt-6-astra`, `xhigh`: event posting, pasteboard privacy, concurrency).
