#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <libproc.h>
#include <stdbool.h>
#include <stdint.h>

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

// proc_pidinfo flavor PROC_PIDUNIQIDENTIFIERINFO (17): the private-SDK struct from xnu bsd/sys/proc_info.h,
// used to verify NStat's uniqueProcessID (== p_uniqueid) against a pid before trusting its start time.
struct tt_proc_uniqidentifierinfo {
    uint8_t p_uuid[16];
    uint64_t p_uniqueid;
    uint64_t p_puniqueid;
    int32_t p_idversion;
    int32_t p_orig_ppidversion;
    uint64_t p_reserve2;
    uint64_t p_reserve3;
};
_Static_assert(sizeof(struct tt_proc_uniqidentifierinfo) == 56, "proc_uniqidentifierinfo layout");

/// p_uniqueid of `pid`; false if unreadable (process gone, or another user's process without permission).
static inline bool tt_proc_uniqueid(int pid, uint64_t *out) {
    struct tt_proc_uniqidentifierinfo info;
    if (proc_pidinfo(pid, 17 /* PROC_PIDUNIQIDENTIFIERINFO */, 0, &info, sizeof(info)) != (int)sizeof(info)) return false;
    *out = info.p_uniqueid;
    return true;
}

/// True when every NStat entry point the sensor calls resolved at load time.
static inline bool tt_nstat_available(void) {
    return &NStatManagerCreate != NULL && &NStatManagerDestroy != NULL && &NStatManagerAddAllTCP != NULL &&
           &NStatManagerAddAllUDP != NULL && &NStatManagerQueryAllSources != NULL &&
           &NStatManagerQueryAllSourcesDescriptions != NULL && &NStatSourceSetDescriptionBlock != NULL && &NStatSourceSetCountsBlock != NULL &&
           &NStatSourceSetRemovedBlock != NULL;
}
