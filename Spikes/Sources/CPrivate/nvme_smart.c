#include "include/NVMeSMART.h"

#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

NVMeSMARTResult nvme_smart_read(io_service_t service) {
    NVMeSMARTResult result;
    memset(&result, 0, sizeof(result));

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        result.stage = 1;
        result.ioReturn = (int)kr;
        return result;
    }

    // IMPORTANT: the plugin (and the Mach connection it owns) must stay alive
    // for the lifetime of the IONVMeSMARTInterface obtained via QueryInterface.
    // Destroying it here (as an earlier version of this file did) tears down
    // the user client's Mach port before SMARTReadData's IPC call reaches it,
    // which fails with kIOReturnIPCError / "(ipc/send) invalid destination
    // port" (0x10000003) even though QueryInterface itself reported success.
    // IODestroyPlugInInterface must run AFTER (*smart)->Release(smart), on
    // every return path below (matches smartmontools' os_darwin.cpp ordering).
    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        result.stage = 2;
        result.ioReturn = (int)hr;
        IODestroyPlugInInterface(plugin);
        return result;
    }

    NVMeSMARTData data;
    memset(&data, 0, sizeof(data));
    IOReturn ret = (*smart)->SMARTReadData(smart, &data);
    if (ret != kIOReturnSuccess) {
        result.stage = 3;
        result.ioReturn = (int)ret;
        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        return result;
    }

    result.success = 1;
    result.stage = 0;
    result.ioReturn = 0;
    result.criticalWarning = data.CRITICAL_WARNING;
    result.temperatureKelvin = data.TEMPERATURE;
    result.percentageUsed = data.PERCENTAGE_USED;
    result.dataUnitsRead = data.DATA_UNITS_READ[0];
    result.dataUnitsWritten = data.DATA_UNITS_WRITTEN[0];
    result.powerOnHours = data.POWER_ON_HOURS[0];
    result.unsafeShutdowns = data.UNSAFE_SHUTDOWNS[0];

    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    return result;
}
