#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

// libIOReport (SDK ships libIOReport.tbd; weak-linked via -weak-lIOReport in Package.swift).
// Implicit bridging: Create/Copy => +1, Get => +0.
// Private functions are weak (ARCHITECTURE §1): check tt_ioreport_available() before calling.
CF_IMPLICIT_BRIDGING_ENABLED
typedef CFTypeRef IOReportSubscriptionRef;

// `group` is effectively required (nil returns nil); use IOReportCopyAllChannels for discovery.
CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c) __attribute__((weak_import));
// Discovery-only: every channel IOReport knows about (~9.5k on M1 Max), no group filter.
CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b) __attribute__((weak_import));
void IOReportMergeChannels(CFMutableDictionaryRef into, CFMutableDictionaryRef from, CFTypeRef unused) __attribute__((weak_import));
IOReportSubscriptionRef IOReportCreateSubscription(void *unused, CFMutableDictionaryRef desired, CFMutableDictionaryRef *subscribed, uint64_t channelID, CFTypeRef unused2) __attribute__((weak_import));
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subscribed, CFTypeRef unused) __attribute__((weak_import));
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef unused) __attribute__((weak_import));

CFStringRef IOReportChannelGetGroup(CFDictionaryRef ch) __attribute__((weak_import));
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef ch) __attribute__((weak_import));
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef ch) __attribute__((weak_import));
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef ch) __attribute__((weak_import));
// 1 = simple (integer), 2 = state (residency), 3 = histogram.
int32_t IOReportChannelGetFormat(CFDictionaryRef ch) __attribute__((weak_import));
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t index) __attribute__((weak_import));
int32_t IOReportStateGetCount(CFDictionaryRef ch) __attribute__((weak_import));
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef ch, int32_t index) __attribute__((weak_import));
int64_t IOReportStateGetResidency(CFDictionaryRef ch, int32_t index) __attribute__((weak_import));
CF_IMPLICIT_BRIDGING_DISABLED

enum { kTTIOReportFormatSimple = 1, kTTIOReportFormatState = 2 };

static inline bool tt_ioreport_available(void) {
    return &IOReportCopyChannelsInGroup != NULL && &IOReportMergeChannels != NULL &&
           &IOReportCreateSubscription != NULL && &IOReportCreateSamples != NULL &&
           &IOReportCreateSamplesDelta != NULL && &IOReportChannelGetGroup != NULL &&
           &IOReportChannelGetSubGroup != NULL && &IOReportChannelGetChannelName != NULL &&
           &IOReportChannelGetUnitLabel != NULL && &IOReportChannelGetFormat != NULL &&
           &IOReportSimpleGetIntegerValue != NULL && &IOReportStateGetCount != NULL &&
           &IOReportStateGetNameForIndex != NULL && &IOReportStateGetResidency != NULL;
}
