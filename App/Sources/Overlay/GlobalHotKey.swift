import Carbon.HIToolbox
import MonitorScreens
import os

/// One system-wide shortcut through Carbon `RegisterEventHotKey` (spec 2026-09-25 overlay, "Hotkey"): works while
/// another app is active and needs no Accessibility permission. `init?` returns nil when the registration fails
/// (another app owns the combination) → `HotKeyStatus.unavailable`. `invalidate()` unregisters; the owner must call
/// it before dropping the instance (a nonisolated deinit cannot touch the Carbon refs; the retained context keeps
/// an un-invalidated registration alive).
@MainActor
final class GlobalHotKey {
    /// Carbon context for the C callback. Retained by `Unmanaged.passRetained` while registered, released on
    /// invalidate; the callback only touches it on the main thread (the application event target runs there).
    @MainActor private final class Box {
        let id: UInt32
        let handler: @MainActor () -> Void
        init(id: UInt32, handler: @escaping @MainActor () -> Void) {
            self.id = id
            self.handler = handler
        }
    }

    private static let signature: OSType = 0x5454_6F76            // 'TTov'
    private static var nextID: UInt32 = 1
    private static let log = Logger(subsystem: "dev.telltale", category: "HotKey")

    let spec: HotKeySpec
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var box: Unmanaged<Box>?

    init?(spec: HotKeySpec, handler: @escaping @MainActor () -> Void) {
        self.spec = spec
        let id = Self.nextID
        Self.nextID &+= 1
        let box = Unmanaged.passRetained(Box(id: id, handler: handler))

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let installed = InstallEventHandler(GetApplicationEventTarget(), GlobalHotKey.callback, 1, &type,
                                            box.toOpaque(), &handlerRef)
        guard installed == noErr, let handlerRef else {
            Self.log.error("InstallEventHandler failed: \(installed)")
            box.release()
            return nil
        }
        var hotKeyRef: EventHotKeyRef?
        let registered = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr, let hotKeyRef else {
            Self.log.notice("RegisterEventHotKey \(spec.display, privacy: .public) failed: \(registered)")
            RemoveEventHandler(handlerRef)
            box.release()
            return nil
        }
        self.hotKeyRef = hotKeyRef
        self.handlerRef = handlerRef
        self.box = box
        Self.log.notice("registered \(spec.display, privacy: .public)")
    }

    func invalidate() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        box?.release()
        hotKeyRef = nil
        handlerRef = nil
        box = nil
    }

    /// Hot-key events arrive on the main thread; other handlers' ids are passed on.
    private static let callback: EventHandlerUPP = { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var hk = EventHotKeyID()
        let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        guard got == noErr, hk.signature == signature else { return OSStatus(eventNotHandledErr) }
        let address = UInt(bitPattern: context)
        let id = hk.id
        return MainActor.assumeIsolated {
            guard let raw = UnsafeRawPointer(bitPattern: address) else { return OSStatus(eventNotHandledErr) }
            let box = Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue()
            guard box.id == id else { return OSStatus(eventNotHandledErr) }
            box.handler()
            return noErr
        }
    }
}
