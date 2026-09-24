import AppKit
import MonitorUIKit

// Before anything touches AppKit text: AppleFontSmoothing = 0 in the process-only argument domain (volatile,
// never persisted), so text renders at the weight of the design references (no stem darkening).
TTTextRendering.configure()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
