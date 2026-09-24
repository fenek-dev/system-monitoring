#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

// Private IOHID pieces not in public headers. Public ones (CopyServices,
// ServiceClientCopyProperty, CreateSimpleClient) come from the includes above.
CF_IMPLICIT_BRIDGING_ENABLED
typedef struct CF_BRIDGED_TYPE(id) __IOHIDEvent *IOHIDEventRef;

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
int32_t IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);
CF_IMPLICIT_BRIDGING_DISABLED

enum { kSMHIDEventTypeTemperature = 15 };  // field = type << 16
