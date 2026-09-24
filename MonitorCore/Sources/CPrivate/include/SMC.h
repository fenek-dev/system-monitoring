#pragma once
#include <IOKit/IOKitLib.h>
#include <stdbool.h>
#include <stdint.h>

// AppleSMC user client (public IOKit only; no private symbols, so no weak imports).
// Byte order of the returned bytes depends on the key family: decode in Swift (SMCDecoder).

io_connect_t smc_open(void);                    // 0 on failure
void smc_close(io_connect_t conn);
// Reads a 4-char key (2 round trips: key info + read). type = FourCC data type (e.g. 'flt ', 'ui8 ').
// bytes must hold 32. Returns 0, -1 (unknown key), -2 (read failed).
int32_t smc_read(io_connect_t conn, const char *key, uint32_t *type, uint8_t *bytes, uint32_t *size);
// Key name at index (0..<#KEY) into out[5] (NUL-terminated).
int32_t smc_key_at(io_connect_t conn, uint32_t index, char *out);
// Key info only (1 round trip). Returns 0 or -1.
int32_t smc_key_info(io_connect_t conn, const char *key, uint32_t *type, uint32_t *size);
// Read with a known size from smc_key_info (1 round trip). size <= 32. Returns 0 or -2.
int32_t smc_read_sized(io_connect_t conn, const char *key, uint32_t size, uint8_t *bytes);

// SMC needs no private symbols; kept for symmetry with the other tt_*_available() checks.
static inline bool tt_smc_available(void) { return true; }
