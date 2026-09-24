import AppKit
import Darwin
import MonitorModel

/// Live process/volume actions (ARCHITECTURE §5.13). Lives in Shell (not App) so `swift test` covers it.
/// - `canControl`: every pid > 1 is owned by `getuid()` and none is synthetic (pid < 0).
/// - quit: `NSRunningApplication.terminate()` for apps, else `SIGTERM`; force quit: `forceTerminate()` / `SIGKILL`.
/// - Reveal in Finder: `activateFileViewerSelecting`; Activity Monitor: `openApplication(at:)`;
///   eject: `unmountAndEjectDevice(at:)`. No "Sample" action (ruling).
public enum ProcessActionsLive {
    public static func make(uid: uid_t = getuid(), owner: @escaping @Sendable (Int32) -> uid_t? = ownerUID)
        -> ProcessActions {
        ProcessActions(
            canControl: { canControl($0, uid: uid, owner: owner) },
            quit: { target in
                guard canControl(target, uid: uid, owner: owner) else { return .notPermitted }
                return signal(target, force: false)
            },
            forceQuit: { target in
                guard canControl(target, uid: uid, owner: owner) else { return .notPermitted }
                return signal(target, force: true)
            },
            revealInFinder: { target in
                guard let url = path(of: target) else { return }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            openInActivityMonitor: { _ in
                let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            },
            eject: { volume in
                guard volume.isEjectable, let url = mountURL(for: volume) else { return .notPermitted }
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return .done
                } catch {
                    return .failed(error.localizedDescription)
                }
            })
    }

    public static func pids(_ t: ProcessTarget) -> [Int32] {
        switch t {
        case .app(_, let pids): pids
        case .process(let pid, _, _, _): [pid]
        }
    }

    /// Pure rule (unit-tested): non-empty, no synthetic (< 0) or kernel/launchd (≤ 1) pid, every owner == uid.
    public static func canControl(_ t: ProcessTarget, uid: uid_t,
                                  owner: (Int32) -> uid_t?) -> Bool {
        let p = pids(t)
        guard !p.isEmpty, p.allSatisfy({ $0 > 1 }) else { return false }
        if case .process(_, _, _, let declared) = t, declared != uid { return false }
        return p.allSatisfy { owner($0) == uid }
    }

    /// Effective owner uid of a live pid (`KERN_PROC_PID`); nil if gone.
    @Sendable public static func ownerUID(_ pid: Int32) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    @MainActor static func signal(_ t: ProcessTarget, force: Bool) -> ActionResult {
        var failures: [String] = []
        for pid in pids(t) {
            if let app = NSRunningApplication(processIdentifier: pid) {
                let ok = force ? app.forceTerminate() : app.terminate()
                if ok { continue }                                  // app refused (e.g. already quitting)
            }
            if kill(pid, force ? SIGKILL : SIGTERM) != 0, errno != ESRCH {
                failures.append("\(pid): \(String(cString: strerror(errno)))")
            }
        }
        return failures.isEmpty ? .done : .failed(failures.joined(separator: ", "))
    }

    /// `VolumeInfo` has no mount path (ARCHITECTURE §5.3 leaves `id` open; w4-report ICR note): an absolute `id` is
    /// taken as the mount path, else the mounted volume whose UUID or name matches.
    static func mountURL(for v: VolumeInfo) -> URL? {
        if v.id.hasPrefix("/") { return URL(fileURLWithPath: v.id) }
        let keys: [URLResourceKey] = [.volumeUUIDStringKey, .volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        return urls.first { url in
            let r = try? url.resourceValues(forKeys: Set(keys))
            return r?.volumeUUIDString == v.id || r?.volumeName == v.name
        }
    }

    static func path(of t: ProcessTarget) -> URL? {
        switch t {
        case .app(let identity, let pids):
            if let b = identity.bundlePath { return URL(fileURLWithPath: b) }
            return pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0)?.bundleURL }.first
        case .process(let pid, _, let path, _):
            if let path { return URL(fileURLWithPath: path) }
            return NSRunningApplication(processIdentifier: pid)?.executableURL
        }
    }
}
