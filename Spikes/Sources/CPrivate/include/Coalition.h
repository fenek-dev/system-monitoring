#pragma once
#include <stddef.h>
#include <stdint.h>

// xnu private declarations (sys/proc_info.h, osfmk/mach/coalition.h), not in the SDK.
// Exported by libSystem. Used by spike-sysmon to test root-process visibility via
// resource coalitions. All calls below work unprivileged on macOS 26.5.
//
// A resource coalition is a SUPERSET of a responsible-pid group: it never splits one,
// but it can hold several responsible roots (e.g. an app plus CLI trees started from it).
// Use it only where proc_pid_rusage is denied (foreign-uid pids) and for per-app
// energy, not as the app key.

#define PROC_PIDCOALITIONINFO 20
#define LISTCOALITIONS_ALL_COALS 1
#define COALITION_TYPE_RESOURCE 0
#define COALITION_TYPE_JETSAM 1

struct proc_pidcoalitioninfo {
    uint64_t coalition_id[2]; // [COALITION_TYPE_RESOURCE], [COALITION_TYPE_JETSAM]
    uint64_t reserved1;
    uint64_t reserved2;
    uint64_t reserved3;
};

struct procinfo_coalinfo {
    uint64_t coalition_id;
    uint32_t coalition_type;
    uint32_t coalition_tasks;
};

// Returns bytes written into buffer, or -1 with errno.
int proc_listcoalitions(int flavor, int coaltype, void *buffer, int buffersize);

// Leading fields of struct coalition_resource_usage. Stable prefix; later fields
// change between releases, so callers pass a larger zeroed buffer.
struct coalition_resource_usage_head {
    uint64_t tasks_started;
    uint64_t tasks_exited;
    uint64_t time_nonempty;
    uint64_t cpu_time;              // mach ticks; ~1% below ps TIME cumulatively, use deltas
    uint64_t interrupt_wakeups;
    uint64_t platform_idle_wakeups;
    uint64_t bytesread;             // bytes
    uint64_t byteswritten;          // bytes
    uint64_t gpu_time;              // UNIT UNKNOWN: ~0.3x AGX accumulatedGPUTime ns. Don't use.
    uint64_t cpu_time_billed_to_me;     // mach ticks; does not explain the cpu_time under-read
    uint64_t cpu_time_billed_to_others; // mach ticks
    uint64_t energy;                // nJ (verified under CPU load). Per-pid own-uid
                                    // equivalent: rusage_info_v6.ri_energy_nj.
};
// Kernel copies 360 bytes (45 x u64) on macOS 26.5.
// Sweep cost: all ~770 resource coalitions in 1.3-2.1 ms.

// cru points at >= sz bytes. Returns 0, or -1 with errno.
int coalition_info_resource_usage(uint64_t cid, void *cru, size_t sz);
