# Warden — Clipboard history (design)

Date: 2026-10-06. Status: approved (interview + plan), implementing.

## Goal
Keep the last clipboard values and paste any of them quickly: a global shortcut opens a picker at the cursor;
Enter (or ⌘1–9, or a click) pastes the chosen item into the app in front.

## Decisions (from the interview)
| Topic | Decision |
|---|---|
| Host | Built into Warden, same process |
| Content | Plain text, images, files. No rich text |
| Shortcut | Global, configurable in Settings. Default ⌘⇧V |
| Picker | Floating panel at the cursor, Telltale dark design system |
| Paste | Selected item goes to the pasteboard, then ⌘V is posted to the front app (needs Accessibility). Without Accessibility the item is only copied and a banner says so |
| History | On disk. 500 items, 30 days. Pinned items exempt from both |
| Duplicates | Copying content already in history moves it to the top |
| Privacy | Copies marked concealed / transient / auto-generated (password managers) are never recorded |
| Search | Fuzzy, over content and source app name |
| Item actions | Pin, delete |
| Clear | One "Clear history" button in Settings (keeps pinned items) |
| Images | Skipped above 20 MB. Stored images capped at 500 MB total (oldest unpinned dropped first) |
| Entry points | Hotkey only. No menu item |
| Out of scope | Rich text, "paste as plain text", sync, per-app exclusion list, pause capture, snippets |

Added while designing (not asked in the interview):
- Text above 2 MB (UTF-8) is not recorded; whitespace-only text is not recorded.
- A copy that has both an image and plain text is text when it also carries RTF (Excel, Word and Keynote put a
  picture of the selection next to the text), otherwise an image (browser "Copy Image" adds a URL string).
- The watcher records nothing that was already on the clipboard when it starts.
- `--mock` never reads the clipboard or the disk: the picker shows fixture items from memory.

## Existing pieces reused
- `GlobalHotKey`: Carbon global shortcut, no permission (`App/Sources/Overlay/GlobalHotKey.swift:11`); registration
  pattern `AppDelegate.registerHotKey` (`App/Sources/AppDelegate.swift:291`).
- `HotKeySpec` (`MonitorCore/Sources/MonitorScreens/Shell/HotKeySpec.swift:5`), `HotKeyRecorder`
  (`Shell/HotKeyRecorder.swift:29`), `HotKeyState` (`Shell/HotKeyRecorder.swift:17`).
- Key-capable non-activating panel: `PopoverPanel` (`App/Sources/Popover/PopoverPanelController.swift:8`).
- Accessibility check and prompt (`App/Sources/Services/ExtraDim/ExtraDimService.swift:81`, `:87`); the Settings
  hook `SettingsStore.openAccessibilitySettings` (`Shell/SettingsStore.swift:61`, set at `ExtraDimService.swift:36`).
- Placement helpers as pure functions (`MonitorScreens/Overlay/OverlayPlacement.swift:5`).
- GRDB open + migrator pattern (`MonitorStore/Database.swift:14`, `MonitorStore/Schema.swift:51`).
- Feature-module precedent: `MixerCore` (`MonitorCore/Package.swift:64`) + `App/Sources/Mixer/`.
- Render catalog for snapshots (`Shell/ScreenCatalog.swift:37`), launch flags (`Shell/LaunchOptions.swift:18`).

## Targets
| Target | Depends on | Contents |
|---|---|---|
| `ClipboardCore` (new) | Foundation only | `ClipItem`, `ClipCapture`, `PasteboardClassifier`, `FuzzyMatcher`, `ClipboardPolicy` |
| `ClipboardStore` (new) | `ClipboardCore`, GRDB, ImageIO | `ClipboardStore` actor: SQLite + image files, retention |
| `MonitorScreens` | + `ClipboardCore` | `ClipboardPickerModel`, `ClipboardPickerView`, `ClipboardPanelPlacement`, settings |
| App | + `ClipboardCore`, `ClipboardStore` | `PasteboardWatcher`, `ClipboardController`, `ClipboardPanelController`, `PasteService` |

UI targets never import `ClipboardStore` (same rule as `MonitorDiskTools`).

## Data
Files: `<data dir>/clipboard/clipboard.sqlite`, `<data dir>/clipboard/images/<hash>.png` and `<hash>.thumb.png`
(thumbnail, longest side 128 px).

`ClipItem` (list row; never holds a full large payload):
- `id: Int64`, `kind: text | image | files`
- `text`: first 2,000 characters (text items), `textLength`: full length
- `files: [String]` (absolute paths)
- `imageFile`, `thumbFile` (file names), `imageWidth`, `imageHeight`
- `byteSize`, `hash`, `sourceBundleID`, `sourceName`, `createdAt`, `lastUsedAt`, `pinned`

Table `clip`: the fields above plus the full `text`; `hash` unique; index on `last_used_at`.
Hash: SHA-256 over a kind tag plus the content (text UTF-8, file paths joined by NUL, original image bytes).

Order everywhere: pinned first, then `lastUsedAt` descending.

Store operations:
- `record(capture, at:)` → inserts, or on an existing hash sets `lastUsedAt` (and the source app) and keeps
  `createdAt` and `pinned`. Then prunes.
- `items()`, `fullText(id)`, `imageData(id)`, `touch(id, at:)`, `setPinned(id, Bool)`, `delete(id)`,
  `clearUnpinned()`, `stats()` (count, bytes).
- Prune (after each record and at open): unpinned items past the newest 500 unpinned, unpinned items with
  `lastUsedAt` older than 30 days, then oldest unpinned images while image bytes exceed 500 MB. Image files of
  removed rows are deleted. At open, image files with no row are deleted.
- A corrupt or non-SQLite file is moved aside (`clipboard.corrupt-<date>.sqlite`) and a fresh one started.

## Capture
`PasteboardWatcher` (App, main actor) checks `NSPasteboard.general.changeCount` every 0.5 s. On a change it reads
the type list and the needed data into a `PasteboardSnapshot`, and `PasteboardClassifier.classify` (pure) returns a
`ClipCapture` or a skip reason:
1. Skip when any type is `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`,
   `org.nspasteboard.AutoGeneratedType`, or our own marker `dev.warden.clipboard.own`.
2. File URLs present → `files`.
3. Image (`public.png`, else `public.tiff`) present, and not (plain text + `public.rtf`) → `image`
   (skip above 20 MB).
4. Plain text present → `text` (skip empty, whitespace-only, above 2 MB).

Source app = `NSWorkspace.shared.frontmostApplication` at capture time. The store converts images to PNG and
writes the thumbnail off the main actor.

## Picker
Fixed size 420 × 460 pt. Top to bottom: search field; Accessibility banner (only when not trusted); list; footer
with key hints.

List rows (44 pt): icon or thumbnail, one-line preview, "app · age", then a ⌘1–⌘9 badge on the first nine rows.
The hovered or selected row shows pin and delete buttons. With an empty query the list has a "Pinned" section
(when any) and a "Recent" section; with a query it is one list ranked by match score, then recency.
States: empty history ("Nothing copied yet"), no matches ("No matches").

Preview: text → first line with whitespace collapsed; image → "Image 1280 × 720"; files → file name, or
"name and N more".

| Key | Action |
|---|---|
| ↑ ↓ | move selection (stops at the ends) |
| ↩ | paste selected |
| ⌘1–⌘9 | paste the nth visible row |
| ⌘P | pin / unpin selected |
| ⌘⌫ | delete selected (plain ⌫ edits the search) |
| Esc | clear the search if any, else close |
| the global shortcut again | close |

Typing always goes to the search field. Changing the query selects the first row.

Panel: `NSPanel`, `.borderless` + `.nonactivatingPanel`, can become key, level `.popUpMenu`, every Space and over
full-screen apps, dark appearance. It opens with its top-left corner 8 pt right of and below the cursor, moved
inside the visible frame of the screen under the cursor. It closes when it stops being key.

## Paste
1. Read the full payload from the store.
2. Write it to the general pasteboard together with the own marker: text as a string, files as file URLs, images
   as PNG and TIFF.
3. Close the panel.
4. If Accessibility is granted, post ⌘V key down/up (`CGEvent`, key code 9) after 60 ms.
5. `touch` the item so it becomes the newest.

Not trusted: steps 1–3 and 5 only, and the first such paste asks for Accessibility once per launch.

## Settings (new "Clipboard" section, after "Overlay")
- "Clipboard history" switch (`clipboard.enabled`, default on). Off: no watcher, no hotkey; history stays on disk.
  Sub-text "Needs Accessibility to paste" with an "Open System Settings" button when not trusted.
- "Shortcut" recorder (`clipboard.hotkey`, default ⌘⇧V). Note for the default: "⌘⇧V replaces Paste and Match
  Style in other apps." Status "Shortcut unavailable — in use by another app" when registration fails.
- "History" row: "N items · X MB" and a "Clear history" button; sub-text "Pinned items are kept".

While either recorder is recording, both global hotkeys are unregistered.

## Launch flags
`--open-clipboard`: opens the picker at launch (verification aid, like `--open-settings`).

## Tests (bug each one catches)
- Re-copy: same content recorded twice gives one row, moved to the top, pin kept.
- Prune: more than 500 / older than 30 days removed, pinned kept, image files removed with their rows, orphan
  image files removed at open, image byte cap drops oldest unpinned first.
- Classifier: concealed, transient, auto-generated and own-marker copies skipped; Finder copy (file URL + name
  string + icon image) is `files`; text + RTF + image is `text`; image + URL string is `image`; size limits.
- Fuzzy matcher: non-matches excluded; contiguous and word-start matches rank above scattered ones; app name
  matches.
- Picker model: selection clamps at both ends; query change selects the first row; ⌘n maps to the nth visible row;
  delete moves the selection to the neighbour.
- Key mapping: ⌘⌫ deletes while plain ⌫ is left to the text field.
- Panel placement: stays inside the visible frame at every screen corner.
- Settings: a stored invalid hotkey falls back to ⌘⇧V.
- Snapshots: picker with items, with pinned section, searching, empty, no matches, Accessibility banner; Settings.
