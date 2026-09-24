import Darwin
import IOKit
import MonitorModel

/// `SensorError.fromErrno` for an errno captured right after the failing call
/// (the Model's `(code, context)` overload is internal to MonitorModel).
func w6aErrnoError(_ code: Int32, _ context: String) -> SensorError {
    switch code {
    case EPERM, EACCES: .permissionDenied("\(context): \(String(cString: strerror(code)))")
    default: .posix(code, context)
    }
}

/// Mach `kern_return_t` → `SensorError` (not errno, so never `.posix`).
func w6aMachError(_ kr: kern_return_t, _ context: String) -> SensorError {
    let text = "\(context): \(String(cString: mach_error_string(kr))) (0x\(String(UInt32(bitPattern: kr), radix: 16)))"
    switch kr {
    case KERN_PROTECTION_FAILURE, KERN_NO_ACCESS: return .permissionDenied(text)
    case KERN_INVALID_ARGUMENT, KERN_NOT_SUPPORTED, KERN_INVALID_HOST: return .unavailable(text)
    default: return .transient(text)
    }
}

/// `IOReturn` → `SensorError`.
func w6aIOReturnError(_ kr: IOReturn, _ context: String) -> SensorError {
    let text = "\(context): IOReturn 0x\(String(UInt32(bitPattern: kr), radix: 16))"
    switch kr {
    case kIOReturnNotPrivileged, kIOReturnNotPermitted: return .permissionDenied(text)
    case kIOReturnUnsupported, kIOReturnNotFound, kIOReturnNoDevice: return .unavailable(text)
    case kIOReturnTimeout: return .timeout
    default: return .transient(text)
    }
}
