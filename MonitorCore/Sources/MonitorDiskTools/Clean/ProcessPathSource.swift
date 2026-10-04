import Darwin
import Foundation

/// Paths currently held by this user's processes.
public struct HeldPaths: Equatable, Sendable {
    /// Executables, working directories and open vnode files (kernel paths are canonical: `/private/var/...`).
    public var paths: [String]
    /// Processes we could not inspect (`EPERM`): they may hold anything, so this is advisory only.
    public var unknownHolders: Int

    public init(paths: [String], unknownHolders: Int = 0) {
        self.paths = paths
        self.unknownHolders = unknownHolders
    }
}

public protocol ProcessPathSource: Sendable {
    func snapshot() -> HeldPaths
}

/// libproc: `proc_listpids` (this user), then per pid `proc_pidpath`, the cwd from `PROC_PIDVNODEPATHINFO`, and every
/// vnode fd via `PROC_PIDLISTFDS` + `PROC_PIDFDVNODEPATHINFO`.
public struct LiveProcessPathSource: ProcessPathSource {
    public init() {}

    public func snapshot() -> HeldPaths {
        var held = HeldPaths(paths: [])
        for pid in userPIDs() where pid > 0 {
            inspect(pid, into: &held)
        }
        return held
    }

    private func userPIDs() -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard bytes > 0 else { return [] }
        // Headroom: processes can start between the size query and the fill.
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 64)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids,
                                   Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled) / MemoryLayout<Int32>.size))
    }

    private func inspect(_ pid: Int32, into held: inout HeldPaths) {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 { held.paths.append(String(cString: path)) }

        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size) == size else {
            // ESRCH: exited mid-sweep. EPERM: not ours to inspect.
            if errno == EPERM { held.unknownHolders += 1 }
            return
        }
        let cwd = Self.string(from: vnodeInfo.pvi_cdir.vip_path)
        if !cwd.isEmpty { held.paths.append(cwd) }

        let listBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard listBytes > 0 else { return }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(),
                                count: Int(listBytes) / MemoryLayout<proc_fdinfo>.size + 16)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
        guard filled > 0 else { return }
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
            let p = Self.string(from: info.pvip.vip_path)
            if !p.isEmpty { held.paths.append(p) }
        }
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
