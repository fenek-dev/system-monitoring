import CoreGraphics
import CPrivate
import Foundation

extension Commands {
    // MARK: brightness

    /// Extra Dim preflight (spec §8): confirms the private backlight read and the gamma table on this machine
    /// before any UI depends on them. Read-only: never writes a gamma table.
    static func brightness() {
        let available = tt_displayservices_available()
        print("DisplayServices: \(available ? "available" : "not present on this macOS")")

        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
            print("display list: CGGetOnlineDisplayList failed")
            return
        }
        let online = ids.prefix(Int(count))
        print("online displays: \(online.map { "\($0)\(CGDisplayIsBuiltin($0) != 0 ? " (built-in)" : "")" }.joined(separator: ", "))")
        guard let builtin = online.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            print("built-in display: none (clamshell?) — Extra Dim would be inert")
            return
        }
        print("built-in display: \(builtin)")

        if available {
            var level: Float = -1
            let rc = DisplayServicesGetBrightness(builtin, &level)
            if rc == 0 {
                print(String(format: "brightness: %.4f%@", level, level <= 0.001 ? " (at system minimum)" : ""))
            } else {
                print("brightness: DisplayServicesGetBrightness returned \(rc)")
            }
        }

        let capacity = CGDisplayGammaTableCapacity(builtin)
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var size: UInt32 = 0
        let err = CGGetDisplayTransferByTable(builtin, capacity, &r, &g, &b, &size)
        guard err == .success else {
            print("gamma table: capacity \(capacity); CGGetDisplayTransferByTable failed (\(err.rawValue))")
            return
        }
        print("gamma table: capacity \(capacity), size \(size)")
        if size > 0 {
            let last = Int(size) - 1
            print(String(format: "gamma ends: r %.4f…%.4f  g %.4f…%.4f  b %.4f…%.4f",
                         r[0], r[last], g[0], g[last], b[0], b[last]))
        }
    }
}
