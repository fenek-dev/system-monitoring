#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <stdbool.h>

// Private IOHID pieces not in public headers (exported by IOKit). Public ones (CopyServices,
// ServiceClientCopyProperty, CreateSimpleClient) come from the includes above.
// Private functions are weak (ARCHITECTURE §1): check tt_hid_available() before calling.
CF_IMPLICIT_BRIDGING_ENABLED
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator) __attribute__((weak_import));
int32_t IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching) __attribute__((weak_import));
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp) __attribute__((weak_import));
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field) __attribute__((weak_import));
CF_IMPLICIT_BRIDGING_DISABLED

enum { kSMHIDEventTypeTemperature = 15 };  // field = type << 16

static inline bool tt_hid_available(void) {
    return &IOHIDEventSystemClientCreate != NULL && &IOHIDEventSystemClientSetMatching != NULL &&
           &IOHIDServiceClientCopyEvent != NULL && &IOHIDEventGetFloatValue != NULL;
}
