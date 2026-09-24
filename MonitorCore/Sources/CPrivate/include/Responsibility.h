#pragma once
#include <sys/types.h>

// libquarantine (re-exported by libSystem). Returns the PID macOS attributes
// a process's resource use to (e.g. Chrome helpers -> Chrome). <= 0 on failure.
pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);
