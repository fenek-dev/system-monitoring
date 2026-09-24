#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <xpc/xpc.h>

// Reverse-engineered libsysmon (/usr/lib/libsysmon.dylib), checked against the
// macOS 26.5 disassembly (see docs/findings/sysmon.md).
//
// - type must be 1, 2 or 3. sysmon_request_add_attribute traps (brk #1) for any other type.
// - attribute bitmap size per type: 1 -> 80 attrs, 2 -> 40, 3 -> 16. Larger attr IDs
//   are logged ("Calculated index ... ") and ignored, not fatal.
// - sysmond drops any client without the "com.apple.sysmond.client" entitlement. The
//   plain handler then receives an EMPTY table (count 0), never NULL, so a rejection is
//   indistinguishable from "no rows". Use sysmon_request_create_with_error.
typedef void *sysmon_request_t;
typedef void *sysmon_table_t;
typedef void *sysmon_row_t;

sysmon_request_t sysmon_request_create(uint8_t type, void (^handler)(sysmon_table_t table));
// On failure: table == NULL and error is a C string such as
// "Disconnected by sysmond server, likely due to bad entitlements".
sysmon_request_t sysmon_request_create_with_error(uint8_t type,
    void (^handler)(sysmon_table_t table, const char *error));
void sysmon_request_add_attribute(sysmon_request_t req, uint32_t attr);
void sysmon_request_execute(sysmon_request_t req);
void sysmon_request_cancel(sysmon_request_t req);
uint64_t sysmon_table_get_count(sysmon_table_t table);
sysmon_row_t sysmon_table_get_row(sysmon_table_t table, uint64_t index);
xpc_object_t sysmon_row_get_value(sysmon_row_t row, uint32_t attr);
void sysmon_row_apply(sysmon_row_t row, bool (^block)(uint32_t attr, xpc_object_t value));
void sysmon_release(void *object);
