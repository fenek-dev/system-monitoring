import AppKit
import ClipboardCore
import os

/// Polls `NSPasteboard.general.changeCount` (there is no change notification) and hands each new copy on as a
/// `ClipCapture`. Skip types are decided from the type list alone, so a concealed copy (password manager) never
/// has its data read.
@MainActor
final class PasteboardWatcher {
    private static let interval: TimeInterval = 0.5
    private static let log = Logger(subsystem: "dev.telltale", category: "Clipboard")

    private let pasteboard: NSPasteboard
    private let handler: @MainActor (ClipCapture) -> Void
    private var timer: Timer?
    private var lastChangeCount = 0

    init(pasteboard: NSPasteboard = .general, handler: @escaping @MainActor (ClipCapture) -> Void) {
        self.pasteboard = pasteboard
        self.handler = handler
    }

    var isRunning: Bool { timer != nil }

    /// Whatever is on the pasteboard now is not history: the baseline is taken here, not on the first tick.
    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)       // `.common`: keeps firing while a menu or panel tracks
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard let capture = readCapture() else { return }
        // Another copy landed between the type check and the reads: what was read may belong to a concealed
        // copy. Drop it; the next tick sees the new count and starts over.
        guard pasteboard.changeCount == count else { return }
        handler(capture)
    }

    private func readCapture() -> ClipCapture? {
        var snapshot = PasteboardSnapshot(types: Set((pasteboard.types ?? []).map(\.rawValue)))
        if case .skip(let reason) = PasteboardClassifier.classify(snapshot), reason == .concealed || reason == .ownWrite {
            Self.log.debug("pasteboard change skipped: \(String(describing: reason), privacy: .public)")
            return nil
        }

        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        snapshot.filePaths = urls.map(\.path)
        snapshot.string = pasteboard.string(forType: .string)
        // Image data can be large or lazily rendered by its owner: ask only when the classifier would use it
        // (not for file copies, not for the picture Office apps add to a text + RTF copy).
        let isRichText = snapshot.string != nil && snapshot.types.contains(NSPasteboard.PasteboardType.rtf.rawValue)
        if snapshot.filePaths.isEmpty && !isRichText {
            snapshot.imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        }

        switch PasteboardClassifier.classify(snapshot) {
        case .capture(let content):
            return ClipCapture(content: content, source: Self.frontmostSource())
        case .skip(let reason):
            Self.log.debug("pasteboard change skipped: \(String(describing: reason), privacy: .public)")
            return nil
        }
    }

    /// The app in front at capture time, which is the one the user copied from; Warden's own copies carry no source.
    private static func frontmostSource() -> ClipSource {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return ClipSource() }
        return ClipSource(bundleID: app.bundleIdentifier, name: app.localizedName)
    }
}
