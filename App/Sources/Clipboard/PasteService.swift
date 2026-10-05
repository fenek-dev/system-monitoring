import AppKit
import ApplicationServices
import ClipboardCore
import os

/// Writes a history item back to the general pasteboard and posts ⌘V to the app in front.
@MainActor
enum PasteService {
    enum Payload {
        case text(String)
        case files([String])
        /// `tiff` is prepared off the main actor (`tiff(fromPNG:)`); nil writes PNG only.
        case image(png: Data, tiff: Data?)
    }

    /// TIFF for apps that do not read PNG from the pasteboard. Decodes the whole image: call off the main actor.
    nonisolated static func tiff(fromPNG png: Data) -> Data? {
        NSBitmapImageRep(data: png)?.tiffRepresentation
    }

    private static let log = Logger(subsystem: "dev.telltale", category: "Clipboard")
    private static let marker = NSPasteboard.PasteboardType(PasteboardClassifier.ownMarkerType)
    private static let vKeyCode: CGKeyCode = 9

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Same call `ExtraDimService` makes: shows the system prompt that links to Privacy › Accessibility.
    @discardableResult static func promptForTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Every write carries the own-marker type so the watcher does not record it again as a new copy.
    /// False when the write failed or the marker is missing: the caller must not post ⌘V.
    static func write(_ payload: Payload, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let written: Bool
        switch payload {
        case .text(let text):
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            item.setData(Data(), forType: marker)
            written = pasteboard.writeObjects([item])
        case .image(let png, let tiff):
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let tiff { item.setData(tiff, forType: .tiff) }
            item.setData(Data(), forType: marker)
            written = pasteboard.writeObjects([item])
        case .files(let paths):
            let urls = paths.map { URL(fileURLWithPath: $0) as NSURL }
            written = pasteboard.writeObjects(urls) && pasteboard.setData(Data(), forType: marker)
        }
        guard written, pasteboard.types?.contains(marker) == true else {
            log.error("pasteboard write failed or own marker missing")
            return false
        }
        return true
    }

    /// ⌘V down and up to the session; the receiving app is the one that is key (the picker never activates Warden).
    static func postPaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("CGEventSource unavailable; paste key not posted")
            return
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: down) else {
                log.error("CGEvent creation failed; paste key not posted")
                return
            }
            event.flags = .maskCommand
            event.post(tap: .cgSessionEventTap)
        }
    }
}
