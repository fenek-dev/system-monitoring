import AppKit
import ClipboardCore
import ClipboardStore
import MonitorScreens
import os

/// Clipboard history (spec 2026-10-06 clipboard history): owns the store, the pasteboard watcher, the picker
/// panel and the global shortcut, and follows `settings.clipboardEnabled` / `clipboardHotKey`. `--mock` keeps the
/// fixture items in memory and never touches the pasteboard or the disk. If the store cannot be opened the feature
/// stays inert (no watcher, no shortcut).
@MainActor
final class ClipboardController {
    private static let log = Logger(subsystem: "dev.telltale", category: "Clipboard")
    /// Pause between closing the picker and posting ⌘V, so key focus is back in the app in front.
    private static let pasteDelay: Duration = .milliseconds(60)

    private struct Key: Equatable {
        var enabled: Bool
        var hotKey: HotKeySpec
    }

    private let env: AppEnvironment
    private let isMock: Bool
    private var model: ClipboardPickerModel!
    private let thumbnails = NSCache<NSString, NSImage>()
    private var panel: ClipboardPanelController!
    private var watcher: PasteboardWatcher!
    private var store: ClipboardStore?
    private var loop: ObservationLoop<Key>?
    private var hotKey: GlobalHotKey?
    private var hotKeyRecording = false
    /// Store open (or mock): the watcher and shortcut may run.
    private var ready = false
    private var isShutDown = false
    private var promptedForTrust = false
    private var pasteTask: Task<Void, Never>?
    /// Bumped each time the picker closes; a paste that started in an earlier session is abandoned.
    private var pickerSession = 0
    private var refreshGeneration = 0

    /// Main-actor mirror of the store, refreshed after every mutation; the picker opens from it instantly.
    private var items: [ClipItem] = []
    private var stats = ClipboardStore.Stats(itemCount: 0, byteSize: 0)

    init(env: AppEnvironment) {
        self.env = env
        isMock = env.options.mockScenario != nil
        model = ClipboardPickerModel(actions: ClipboardPickerModel.Actions(
            paste: { [weak self] item in self?.paste(item) },
            setPinned: { [weak self] item, pinned in self?.setPinned(item, pinned) },
            delete: { [weak self] item in self?.delete(item) },
            close: { [weak self] in self?.panel.close() },
            openAccessibilitySettings: { [weak self] in
                self?.env.settings.openAccessibilitySettings?()
                self?.panel.close()
            }),
            thumbnail: { [weak self] item in self?.thumbnail(for: item) })
        panel = ClipboardPanelController(model: model) { [weak self] in self?.pickerSession += 1 }
        watcher = PasteboardWatcher { [weak self] capture in self?.record(capture) }
    }

    func start() {
        Self.log.notice("start mock=\(self.isMock, privacy: .public) accessibilityTrusted=\(PasteService.isTrusted, privacy: .public)")
        let settings = env.settings
        settings.refreshClipboardStatus = { [weak self] in
            ClipboardStatus(needsAccessibility: !PasteService.isTrusted, itemCount: self?.stats.itemCount ?? 0,
                            byteSize: self?.stats.byteSize ?? 0)
        }
        settings.clearClipboardHistory = { [weak self] in self?.clearHistory() }

        if isMock {
            publish(ClipboardFixture.items(now: Date()))
            becomeReady()
            return
        }
        let directory = env.dataDirectory.appendingPathComponent("clipboard")
        Task { [weak self] in
            do {
                let store = try await Task.detached { try ClipboardStore(location: .directory(directory), now: Date()) }.value
                guard let self, !isShutDown else { return }
                self.store = store
                await refresh()
                becomeReady()
            } catch {
                Self.log.error("clipboard store unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func setHotKeyRecording(_ recording: Bool) {
        guard recording != hotKeyRecording else { return }
        hotKeyRecording = recording
        applyHotKey()
    }

    func toggle() {
        guard ready, !isShutDown else { return }
        if panel.isShown { return panel.close() }
        model.reset(items: items, now: Date())
        model.needsAccessibility = !PasteService.isTrusted
        panel.show()
        if store != nil { Task { await refresh() } }
    }

    func shutdown() {
        isShutDown = true
        loop?.cancel()
        loop = nil
        watcher.stop()
        unregisterHotKey()
        panel.close()
    }

    // MARK: Settings

    private func becomeReady() {
        ready = true
        let settings = env.settings
        loop = ObservationLoop({ Key(enabled: settings.clipboardEnabled, hotKey: settings.clipboardHotKey) }) {
            [weak self] key in self?.apply(key)
        }
    }

    private func apply(_ key: Key) {
        guard ready, !isShutDown else { return }
        if key.enabled {
            if !isMock { watcher.start() }
            applyHotKey()
        } else {
            watcher.stop()
            unregisterHotKey()
            env.hotKeyState.clipboardStatus = .registered
            panel.close()
        }
    }

    /// Re-registers `settings.clipboardHotKey` unless the feature is off or a recorder is capturing keys.
    private func applyHotKey() {
        guard ready, !isShutDown else { return }
        unregisterHotKey()
        let settings = env.settings
        guard settings.clipboardEnabled, !hotKeyRecording else {
            env.hotKeyState.clipboardStatus = .registered
            return
        }
        hotKey = GlobalHotKey(spec: settings.clipboardHotKey) { [weak self] in self?.toggle() }
        env.hotKeyState.clipboardStatus = hotKey == nil ? .unavailable : .registered
    }

    private func unregisterHotKey() {
        hotKey?.invalidate()
        hotKey = nil
    }

    // MARK: History

    private func publish(_ new: [ClipItem]) {
        items = new
        stats = ClipboardStore.Stats(itemCount: new.count, byteSize: new.reduce(0) { $0 + $1.byteSize })
        if panel.isShown { model.items = new }
    }

    /// A refresh that was overtaken (by a newer refresh, or by a pin/delete/clear that started after it read) is
    /// dropped, so a deleted row cannot reappear; the newer one publishes.
    private func refresh() async {
        guard let store else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        do {
            let new = try await store.items()
            let stats = try await store.stats()
            guard generation == refreshGeneration else { return }
            items = new
            self.stats = stats
            if panel.isShown { model.items = new }
        } catch {
            Self.log.error("clipboard refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func record(_ capture: ClipCapture) {
        guard let store else { return }
        Task {
            do {
                let item = try await store.record(capture, at: Date())
                Self.log.debug("recorded kind=\(capture.kind.rawValue, privacy: .public) stored=\(item != nil, privacy: .public)")
                await refresh()
            } catch {
                Self.log.error("record failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func setPinned(_ item: ClipItem, _ pinned: Bool) {
        guard let store else {
            publish(items.map { var copy = $0; if copy.id == item.id { copy.pinned = pinned }; return copy })
            return
        }
        refreshGeneration += 1
        Task {
            do { try await store.setPinned(item.id, pinned) } catch {
                Self.log.error("pin failed: \(error.localizedDescription, privacy: .public)")
            }
            await refresh()
        }
    }

    private func delete(_ item: ClipItem) {
        guard let store else {
            publish(items.filter { $0.id != item.id })
            return
        }
        refreshGeneration += 1
        Task {
            do { try await store.delete(item.id) } catch {
                Self.log.error("delete failed: \(error.localizedDescription, privacy: .public)")
            }
            await refresh()
        }
    }

    private func clearHistory() {
        guard let store else {
            publish(items.filter(\.pinned))
            return
        }
        refreshGeneration += 1
        Task {
            do { try await store.clearUnpinned() } catch {
                Self.log.error("clear failed: \(error.localizedDescription, privacy: .public)")
            }
            await refresh()
        }
    }

    // MARK: Paste (spec "Paste")

    private func paste(_ item: ClipItem) {
        guard let store else {
            panel.close()                                   // mock: nothing is written to the pasteboard
            return
        }
        guard pasteTask == nil else { return }              // one paste at a time: a second pick would paste twice
        let session = pickerSession
        pasteTask = Task {
            defer { pasteTask = nil }
            let payload = await payload(for: item, in: store)
            // The picker was closed (or the feature stopped) while the payload loaded: the user has moved on, and
            // ⌘V would land in whatever is in front now.
            guard session == pickerSession, panel.isShown, !isShutDown else { return }
            guard let payload else {
                Self.log.error("paste: payload for \(item.kind.rawValue, privacy: .public) item is gone")
                panel.close()
                return
            }
            guard PasteService.write(payload) else { return panel.close() }
            panel.close()
            let closedSession = pickerSession
            if PasteService.isTrusted {
                try? await Task.sleep(for: Self.pasteDelay)
                // Reopened during the pause: ⌘V would go to the picker's own search field.
                guard closedSession == pickerSession, !panel.isShown, !isShutDown else { return }
                PasteService.postPaste()
            } else if !promptedForTrust {
                promptedForTrust = true
                PasteService.promptForTrust()
            }
            do { try await store.touch(item.id, at: Date()) } catch {
                Self.log.error("touch failed: \(error.localizedDescription, privacy: .public)")
            }
            await refresh()
        }
    }

    private func payload(for item: ClipItem, in store: ClipboardStore) async -> PasteService.Payload? {
        do {
            switch item.kind {
            case .text: return try await store.fullText(item.id).map { .text($0) }
            case .image:
                guard let png = try await store.imageData(item.id) else { return nil }
                let tiff = await Task.detached { PasteService.tiff(fromPNG: png) }.value
                return .image(png: png, tiff: tiff)
            case .files: return item.files.isEmpty ? nil : .files(item.files)
            }
        } catch {
            Self.log.error("payload load failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func thumbnail(for item: ClipItem) -> NSImage? {
        guard let store, let file = item.thumbFile else { return nil }
        if let cached = thumbnails.object(forKey: file as NSString) { return cached }
        guard let image = NSImage(contentsOf: store.imagesDirectory.appendingPathComponent(file)) else { return nil }
        thumbnails.setObject(image, forKey: file as NSString)
        return image
    }
}
