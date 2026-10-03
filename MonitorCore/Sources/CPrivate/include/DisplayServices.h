#pragma once
#include <CoreGraphics/CGDirectDisplay.h>
#include <stdbool.h>

// Private DisplayServices.framework (weak-linked: -weak_framework DisplayServices in Package.swift). Extra Dim reads
// the built-in display's backlight level (0…1) to know when it sits at the system minimum.
// Returns 0 on success. Private functions are weak (ARCHITECTURE §1): check tt_displayservices_available() first.
extern int DisplayServicesGetBrightness(CGDirectDisplayID display, float *brightness) __attribute__((weak_import));

static inline bool tt_displayservices_available(void) { return &DisplayServicesGetBrightness != NULL; }
