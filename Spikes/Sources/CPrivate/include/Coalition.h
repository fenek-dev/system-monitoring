#pragma once
#include <stddef.h>
#include <stdint.h>

// xnu private declarations (sys/proc_info.h, osfmk/mach/coalition.h), not in the SDK.
// Exported by libSystem. Used by spike-sysmon to test root-process visibility via
// resource coalitions.

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
    uint64_t cpu_time;              // mach absolute time units
    uint64_t interrupt_wakeups;
    uint64_t platform_idle_wakeups;
    uint64_t bytesread;
    uint64_t byteswritten;
    uint64_t gpu_time;
    uint64_t cpu_time_billed_to_me;
    uint64_t cpu_time_billed_to_others;
    uint64_t energy;                // nJ
};

// cru points at >= sz bytes. Returns 0, or -1 with errno.
int coalition_info_resource_usage(uint64_t cid, void *cru, size_t sz);
