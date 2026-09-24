#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// xnu private declarations (sys/proc_info.h, osfmk/mach/coalition.h), not in the SDK. Exported by
// libSystem; all calls work unprivileged on macOS 26.5 (docs/findings/sysmon.md §C).
//
// A resource coalition is a SUPERSET of a responsible-pid group: it never splits one, but it can hold
// several responsible roots. Use it only where proc_pid_rusage is denied (foreign-uid pids) and for
// per-app energy, never as the app key.
// The kernel exposes no leader query: CoalitionSensor names the earliest-started live member the leader.
//
// Private functions are weak (ARCHITECTURE §1): check tt_coalition_available() before calling.

#define PROC_PIDCOALITIONINFO 20
#define LISTCOALITIONS_ALL_COALS 1
#define COALITION_TYPE_RESOURCE 0
#define COALITION_TYPE_JETSAM 1

// proc_pidinfo(pid, PROC_PIDCOALITIONINFO, ...): public libproc call, private flavor. Unprivileged for all pids.
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
int proc_listcoalitions(int flavor, int coaltype, void *buffer, int buffersize) __attribute__((weak_import));

// struct coalition_resource_usage as copied out by macOS 26.5: 360 bytes (45 x u64), measured with a
// sentinel fill. Words [0]..[11] are the stable, verified prefix; the rest is carried opaquely.
// The sensor re-verifies the size at prepare() (ARCHITECTURE §6 sentinel-fill check).
struct coalition_resource_usage {
    uint64_t tasks_started;
    uint64_t tasks_exited;
    uint64_t time_nonempty;
    uint64_t cpu_time;              // [3] mach ticks; ~1% below ps TIME cumulatively, use deltas
    uint64_t interrupt_wakeups;
    uint64_t platform_idle_wakeups;
    uint64_t bytesread;             // [6] bytes
    uint64_t byteswritten;          // [7] bytes
    uint64_t gpu_time;              // [8] UNIT UNKNOWN (~0.3x AGX accumulatedGPUTime ns). Never used.
    uint64_t cpu_time_billed_to_me;     // [9] mach ticks; does not explain the cpu_time under-read
    uint64_t cpu_time_billed_to_others; // [10] mach ticks
    uint64_t energy;                // [11] nJ (verified under CPU load); per-pid equivalent: ri_energy_nj
    uint64_t unverified_tail[33];   // [12]..[44]
};
_Static_assert(sizeof(struct coalition_resource_usage) == 360,
               "coalition_resource_usage must match the 360-byte layout measured on macOS 26.5");

// cru points at >= sz bytes; the kernel copies min(sz, its struct size). Returns 0, or -1 with errno.
int coalition_info_resource_usage(uint64_t cid, void *cru, size_t sz) __attribute__((weak_import));

static inline bool tt_coalition_available(void) {
    return &proc_listcoalitions != NULL && &coalition_info_resource_usage != NULL;
}
