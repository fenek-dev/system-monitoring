#import <Foundation/Foundation.h>
#include "SnapshotProcessSetup.h"

// Test-process text rendering, fixed before ANY test runs (ARCHITECTURE §8 goldens).
//
// AppKit/SwiftUI/Core Animation latch font smoothing once per process, at the first text layout, and rasterize glyphs
// in their own contexts: a snapshot CGContext's setShouldSmoothFonts(false) does not reach them. So whichever test lays
// out text first (in any target: they all share one test bundle/process) decides how every golden renders. Swift
// Testing has no global setup hook, so this image constructor runs when the test bundle is loaded, before the runner
// starts any test. Same effect as `TTTextRendering.configure()` (argument domain only; nothing persisted).
// Linked only through MonitorSnapshotTesting (test-only), never by the app, which calls configure() first in main.

static bool configuredAtLoad = false;

__attribute__((constructor)) static void tt_snapshot_configure_text_rendering(void) {
    @autoreleasepool {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *domain = [[defaults volatileDomainForName:NSArgumentDomain] mutableCopy]
            ?: [NSMutableDictionary dictionary];
        domain[@"AppleFontSmoothing"] = @0;
        [defaults setVolatileDomain:domain forName:NSArgumentDomain];
        configuredAtLoad = true;
    }
}

bool tt_snapshot_text_rendering_configured_at_load(void) { return configuredAtLoad; }
