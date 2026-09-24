#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

// Private NetworkStatistics.framework (what nettop uses). Reverse-engineered; spike validates.
typedef void *NStatManagerRef;
typedef void *NStatSourceRef;

CF_IMPLICIT_BRIDGING_ENABLED
NStatManagerRef NStatManagerCreate(CFAllocatorRef allocator, dispatch_queue_t queue, void (^added)(NStatSourceRef source, void *unknown));
void NStatManagerDestroy(NStatManagerRef mgr);
void NStatManagerAddAllTCP(NStatManagerRef mgr);
void NStatManagerAddAllUDP(NStatManagerRef mgr);
void NStatManagerQueryAllSources(NStatManagerRef mgr, void (^done)(void));
void NStatManagerQueryAllSourcesDescriptions(NStatManagerRef mgr, void (^done)(void));
void NStatSourceSetDescriptionBlock(NStatSourceRef src, void (^block)(CFDictionaryRef description));
void NStatSourceSetCountsBlock(NStatSourceRef src, void (^block)(CFDictionaryRef counts));
void NStatSourceSetRemovedBlock(NStatSourceRef src, void (^block)(void));

extern const CFStringRef kNStatSrcKeyPID;
extern const CFStringRef kNStatSrcKeyProcessName;
extern const CFStringRef kNStatSrcKeyProvider;
extern const CFStringRef kNStatSrcKeyRxBytes;
extern const CFStringRef kNStatSrcKeyTxBytes;
CF_IMPLICIT_BRIDGING_DISABLED
