import Darwin
import MonitorModel

/// `SensorError.fromErrno` for an errno captured right after the failing call
/// (the Model's `(code, context)` overload is internal to MonitorModel).
func w6aErrnoError(_ code: Int32, _ context: String) -> SensorError {
    switch code {
    case EPERM, EACCES: .permissionDenied("\(context): \(String(cString: strerror(code)))")
    default: .posix(code, context)
    }
}
