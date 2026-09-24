#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// libIOReport (SDK ships libIOReport.tbd). Implicit bridging: Create/Copy => +1, Get => +0.
CF_IMPLICIT_BRIDGING_ENABLED
typedef CFTypeRef IOReportSubscriptionRef;

CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
// Discovery-only extra: lists every channel IOReport knows about, no group filter.
CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
void IOReportMergeChannels(CFMutableDictionaryRef into, CFMutableDictionaryRef from, CFTypeRef unused);
IOReportSubscriptionRef IOReportCreateSubscription(void *unused, CFMutableDictionaryRef desired, CFMutableDictionaryRef *subscribed, uint64_t channelID, CFTypeRef unused2);
CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subscribed, CFTypeRef unused);
CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef cur, CFTypeRef unused);

CFStringRef IOReportChannelGetGroup(CFDictionaryRef ch);
CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef ch);
CFStringRef IOReportChannelGetChannelName(CFDictionaryRef ch);
CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef ch);
int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef ch, int32_t index);
int32_t IOReportStateGetCount(CFDictionaryRef ch);
CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef ch, int32_t index);
int64_t IOReportStateGetResidency(CFDictionaryRef ch, int32_t index);
CF_IMPLICIT_BRIDGING_DISABLED
