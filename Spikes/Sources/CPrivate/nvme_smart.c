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

    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    IODestroyPlugInInterface(plugin);
    if (hr != S_OK || smart == NULL) {
        result.stage = 2;
        result.ioReturn = (int)hr;
        return result;
    }

    NVMeSMARTData data;
    memset(&data, 0, sizeof(data));
    IOReturn ret = (*smart)->SMARTReadData(smart, &data);
    if (ret != kIOReturnSuccess) {
        result.stage = 3;
        result.ioReturn = (int)ret;
        (*smart)->Release(smart);
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
    return result;
}
