import Darwin
import Dispatch
import Foundation
import MonitorModel

/// Detects that the scanned volume is going or gone (spec §5.2): an unmount notification for a mount point above
/// the root, a revoked root descriptor (forced removal), or a listing failing with a device-gone errno.
enum VolumeWatch {
    /// `mountPath` is the volume about to unmount (`NSWorkspace.willUnmountNotification`). It affects the scan when
    /// the root lies on or below it, matched by whole path components; `/` can never unmount while the app runs, and
    /// matching it would cancel every scan.
    static func unmountAffects(mountPath: String, rootPath: String) -> Bool {
        let mount = mountPath.split(separator: "/", omittingEmptySubsequences: true)
        guard !mount.isEmpty else { return false }
        let root = rootPath.split(separator: "/", omittingEmptySubsequences: true)
        return root.starts(with: mount)
    }

    /// A listing that fails like this means the device went away mid-walk.
    static func isVolumeGone(errno code: Int32) -> Bool {
        code == ENXIO || code == EIO || code == ENODEV
    }

    /// Fires `onRevoke` when the root's descriptor is revoked (forced removal). nil when the root cannot be opened
    /// for event notification: the other two signals still apply.
    static func watchRevocation(path: String, onRevoke: @escaping @Sendable () -> Void) -> Watch? {
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            DiskTools.log.info("revoke watch for \(path) unavailable, errno \(Darwin.errno)")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .revoke,
                                                               queue: .global(qos: .utility))
        source.setEventHandler(handler: onRevoke)
        source.setCancelHandler { _ = Darwin.close(fd) }
        source.resume()
        return Watch(source: source)
    }

    final class Watch: Sendable {
        private let source: any DispatchSourceFileSystemObject

        fileprivate init(source: any DispatchSourceFileSystemObject) {
            self.source = source
        }

        func cancel() { source.cancel() }
    }
}
