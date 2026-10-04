import Darwin

/// Per-thread "never materialize iCloud placeholders" policy (spikes §8): touching a dataless file or directory
/// from a thread without it triggers a download.
enum DatalessPolicy {
    /// For threads this module owns (scan workers): off for the thread's whole life.
    static func disableForCurrentThread() {
        if setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                          IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0 {
            DiskTools.log.error("setiopolicy_np(materialize dataless) failed, errno \(Darwin.errno)")
        }
    }

    /// For borrowed threads (the engine's `.utility` queue): off while `body` runs, then the previous setting.
    static func withMaterializationOff<R>(_ body: () -> R) -> R {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        disableForCurrentThread()
        defer {
            if previous >= 0,
               setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) != 0 {
                DiskTools.log.error("restoring materialize policy failed, errno \(Darwin.errno)")
            }
        }
        return body()
    }
}
