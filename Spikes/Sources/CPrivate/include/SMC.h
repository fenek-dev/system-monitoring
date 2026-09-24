#pragma once
#include <IOKit/IOKitLib.h>
#include <stdint.h>

io_connect_t smc_open(void);                    // 0 on failure
void smc_close(io_connect_t conn);
// Reads a 4-char key. type = FourCC data type (e.g. 'flt ', 'ui8 '). bytes must hold 32.
int32_t smc_read(io_connect_t conn, const char *key, uint32_t *type, uint8_t *bytes, uint32_t *size);
// Key name at index (0..<#KEY) into out[5] (NUL-terminated).
int32_t smc_key_at(io_connect_t conn, uint32_t index, char *out);
