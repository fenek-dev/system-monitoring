#pragma once
#include <IOKit/IOKitLib.h>

// Thin C wrapper around the COM-style NVMeSMARTLib CFPlugIn
// (<IOKit/storage/nvme/NVMeSMARTLibExternal.h>). Calling a CFPlugIn's vtable
// (IUNKNOWN_C_GUTS, HRESULT/REFIID/LPVOID types) from Swift directly is
// awkward, so the plugin dance (IOCreatePlugInInterfaceForService ->
// QueryInterface -> SMARTReadData -> Release) lives here in C, and Swift only
// sees this plain struct + one function.
typedef struct {
    int success;        // 1 if SMARTReadData succeeded and fields below are valid
    int stage;           // 0 = ok; 1 = IOCreatePlugInInterfaceForService failed;
                          // 2 = QueryInterface failed; 3 = SMARTReadData failed
    int ioReturn;         // stage-specific IOReturn/HRESULT/kern_return_t code
    unsigned char criticalWarning;
    unsigned short temperatureKelvin;
    unsigned char percentageUsed;
    unsigned long long dataUnitsRead;     // low 64 bits of the 128-bit counter; x512000 = bytes
    unsigned long long dataUnitsWritten;  // low 64 bits of the 128-bit counter; x512000 = bytes
    unsigned long long powerOnHours;      // low 64 bits
    unsigned long long unsafeShutdowns;   // low 64 bits
} NVMeSMARTResult;

// service must be an io_service_t with the "NVMe SMART Capable" property set.
// Does not consume/release the caller's reference on `service`.
NVMeSMARTResult nvme_smart_read(io_service_t service);
