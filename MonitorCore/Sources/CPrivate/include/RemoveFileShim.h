#pragma once
#include <stdint.h>

// Public libSystem API (removefile.h, <sys/removefile.h> values) that the Darwin Swift module doesn't import, and
// that is not reachable through `#include <removefile.h>` from inside this module. Declared by hand; used by
// MonitorDiskTools' DeleteWorker. Values match removefile.h.
typedef struct _removefile_state *tt_removefile_state_t;
typedef int (*tt_removefile_callback_t)(tt_removefile_state_t state, const char *path, void *context);

tt_removefile_state_t removefile_state_alloc(void);
int removefile_state_free(tt_removefile_state_t state);
int removefile_state_get(tt_removefile_state_t state, uint32_t key, void *dst);
int removefile_state_set(tt_removefile_state_t state, uint32_t key, const void *value);
int removefileat(int fd, const char *path, tt_removefile_state_t state, uint32_t flags);
int removefile_cancel(tt_removefile_state_t state);

enum {
    TT_REMOVEFILE_RECURSIVE = 1 << 0,
    TT_REMOVEFILE_RECURSIVE_SLIM = 1 << 11,
    TT_REMOVEFILE_STATE_ERROR_CALLBACK = 3,
    TT_REMOVEFILE_STATE_ERROR_CONTEXT = 4,
    TT_REMOVEFILE_STATE_ERRNO = 5,
    TT_REMOVEFILE_SKIP = 1,
};
