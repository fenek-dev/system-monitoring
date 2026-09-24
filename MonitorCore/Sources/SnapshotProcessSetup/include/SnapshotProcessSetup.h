#pragma once
#include <stdbool.h>

/// True once the load-time constructor has put `AppleFontSmoothing = 0` in this process's argument domain.
bool tt_snapshot_text_rendering_configured_at_load(void);
