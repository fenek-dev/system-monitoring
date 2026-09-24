#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

// libquarantine (re-exported by libSystem), no public header. Returns the PID macOS attributes
// a process's resource use to (e.g. Chrome helpers -> Chrome). <= 0 on failure.
// Returns nothing for foreign-uid pids when unprivileged (docs/findings/sysmon.md).
// Weak: a missing symbol leaves the address NULL instead of failing app launch (ARCHITECTURE §1).
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid) __attribute__((weak_import));

static inline bool tt_responsibility_available(void) {
    return &responsibility_get_pid_responsible_for_pid != NULL;
}
