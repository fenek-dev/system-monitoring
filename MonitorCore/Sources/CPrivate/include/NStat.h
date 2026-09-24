#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>

// Private NetworkStatistics.framework (what nettop uses). Reverse-engineered; verified in
// docs/findings/nstat.md. Weak-linked (Package.swift: -weak_framework NetworkStatistics): check
// tt_nstat_available() before calling anything here.
//
// All callbacks (added / description / counts / removed / query-done) fire on the queue passed to
// NStatManagerCreate. A source's description and counts dictionaries have the same shape
// (processID, uniqueProcessID, epid, processName, provider, rxBytes, txBytes, localAddress,
// remoteAddress (CFData sockaddr), interface, TCPState (TCP only), ...). Key names beyond the five
// exported constants are discovered at runtime, not linked.
typedef void *NStatManagerRef;
typedef void *NStatSourceRef;

CF_IMPLICIT_BRIDGING_ENABLED
NStatManagerRef NStatManagerCreate(CFAllocatorRef allocator, dispatch_queue_t queue, void (^added)(NStatSourceRef source, void *unknown)) __attribute__((weak_import));
void NStatManagerDestroy(NStatManagerRef mgr) __attribute__((weak_import));
void NStatManagerAddAllTCP(NStatManagerRef mgr) __attribute__((weak_import));
void NStatManagerAddAllUDP(NStatManagerRef mgr) __attribute__((weak_import));
void NStatManagerQueryAllSources(NStatManagerRef mgr, void (^done)(void)) __attribute__((weak_import));
void NStatManagerQueryAllSourcesDescriptions(NStatManagerRef mgr, void (^done)(void)) __attribute__((weak_import));
void NStatSourceSetDescriptionBlock(NStatSourceRef src, void (^block)(CFDictionaryRef description)) __attribute__((weak_import));
void NStatSourceSetCountsBlock(NStatSourceRef src, void (^block)(CFDictionaryRef counts)) __attribute__((weak_import));
void NStatSourceSetRemovedBlock(NStatSourceRef src, void (^block)(void)) __attribute__((weak_import));

extern const CFStringRef kNStatSrcKeyPID __attribute__((weak_import));
extern const CFStringRef kNStatSrcKeyProcessName __attribute__((weak_import));
extern const CFStringRef kNStatSrcKeyProvider __attribute__((weak_import));
extern const CFStringRef kNStatSrcKeyRxBytes __attribute__((weak_import));
extern const CFStringRef kNStatSrcKeyTxBytes __attribute__((weak_import));
CF_IMPLICIT_BRIDGING_DISABLED

/// True when every NStat entry point the sensor calls resolved at load time.
static inline bool tt_nstat_available(void) {
    return &NStatManagerCreate != NULL && &NStatManagerDestroy != NULL && &NStatManagerAddAllTCP != NULL &&
           &NStatManagerAddAllUDP != NULL && &NStatManagerQueryAllSources != NULL &&
           &NStatSourceSetDescriptionBlock != NULL && &NStatSourceSetCountsBlock != NULL &&
           &NStatSourceSetRemovedBlock != NULL;
}
