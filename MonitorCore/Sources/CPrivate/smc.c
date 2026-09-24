#include "SMC.h"
#include <mach/mach.h>
#include <string.h>

// AppleSMC user-client struct layout (selector 2). Must be 80 bytes.
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;
_Static_assert(sizeof(SMCParam) == 80, "SMCParam layout");

enum { kSMCUserClient = 2, kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static kern_return_t call(io_connect_t c, SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    return IOConnectCallStructMethod(c, kSMCUserClient, in, sizeof(SMCParam), out, &outSize);
}

io_connect_t smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return 0;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS ? conn : 0;
}

void smc_close(io_connect_t conn) { if (conn) IOServiceClose(conn); }

int32_t smc_read(io_connect_t c, const char *key, uint32_t *type, uint8_t *bytes, uint32_t *size) {
    SMCParam in = {0}, out = {0};
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    if (call(c, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    uint32_t sz = out.keyInfo.dataSize;
    *type = out.keyInfo.dataType;
    in.keyInfo.dataSize = sz;
    in.data8 = kSMCReadKey;
    memset(&out, 0, sizeof out);
    if (call(c, &in, &out) != KERN_SUCCESS || out.result != 0) return -2;
    if (sz > 32) sz = 32;
    memcpy(bytes, out.bytes, sz);
    *size = sz;
    return 0;
}

int32_t smc_key_at(io_connect_t c, uint32_t index, char *outKey) {
    SMCParam in = {0}, out = {0};
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    if (call(c, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    outKey[0] = (char)(out.key >> 24); outKey[1] = (char)(out.key >> 16);
    outKey[2] = (char)(out.key >> 8);  outKey[3] = (char)out.key; outKey[4] = 0;
    return 0;
}
