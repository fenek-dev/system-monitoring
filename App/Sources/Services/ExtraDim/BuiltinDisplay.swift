import AppKit
import CoreGraphics
import CPrivate
import os

/// The built-in display (extra-dim spec §3): its `CGDirectDisplayID`, its `NSScreen`, and its backlight level through
/// the weak private `DisplayServicesGetBrightness`. No built-in display (clamshell) → `id` is nil and Extra Dim is inert.
@MainActor
final class BuiltinDisplay {
    private let log = Logger(subsystem: "dev.telltale", category: "ExtraDim")
    private var loggedReadFailure = false

    /// DisplayServices is present on this macOS (else the feature is unavailable, spec §7).
    static var brightnessAvailable: Bool { tt_displayservices_available() }

    /// The online built-in display, if any.
    var id: CGDirectDisplayID? {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Backlight 0…1; nil when unavailable or the read fails (treated as "not at min": keys pass through).
    /// A failure is logged once per session.
    func brightness(_ display: CGDirectDisplayID) -> Float? {
        guard Self.brightnessAvailable else { return nil }
        var value: Float = 0
        let rc = DisplayServicesGetBrightness(display, &value)
        guard rc == 0 else {
            if !loggedReadFailure {
                loggedReadFailure = true
                log.error("DisplayServicesGetBrightness(\(display)) failed: \(rc)")
            }
            return nil
        }
        return value
    }

    func screen(_ display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
    }
}
