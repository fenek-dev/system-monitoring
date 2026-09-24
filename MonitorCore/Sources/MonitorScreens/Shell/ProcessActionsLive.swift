import AppKit
import Darwin
import MonitorModel

/// Live process/volume actions (ARCHITECTURE §5.13). Lives in Shell (not App) so `swift test` covers it.
/// - `canControl`: every pid > 1 is owned by `getuid()`, none is synthetic (pid < 0), and the target is not Telltale
///   itself (`ProcessTarget.isSelf`, the same rule as the row menu). Quit/Force Quit use `gate`: the same rules,
///   but exited members are dropped before the owner check (all gone → `.exited`, a live foreign one →
///   `.notPermitted`).
/// - Every pid is re-verified (pid + start time, `KERN_PROC_PID`) right before it is signalled; a pid that has
///   exited or been reused is never signalled. When no target process is left the result is `.exited`.
/// - Quit (DESIGN §2.25 ruling): a `.process` gets `terminate()` (LS app) or SIGTERM. An `.app` group asks only
///   the app to quit: `terminate()` on its members that are regular apps (`activationPolicy != .prohibited`); a
///   bundle-less group gets SIGTERM on its leader only (earliest-started member, i.e. the responsible process).
///   Helpers are never signalled. `.done` once the recipients are gone within `quitWait`, else `.requested`.
/// - Force Quit: `forceTerminate()` / SIGKILL on every member (each start-time verified).
/// - Reveal in Finder: `activateFileViewerSelecting`; Activity Monitor: `openApplication(at:)`;
///   eject: `unmountAndEjectDevice(at:)`. [Sample] is a separate service (`ProcessSampling`).
public enum ProcessActionsLive {
    public static func make(uid: uid_t = getuid(), owner: @escaping @Sendable (Int32) -> uid_t? = ownerUID,
                            startTime: @escaping @Sendable (Int32) -> UInt64? = liveStartTimeUs,
                            quitWait: Duration = .seconds(2)) -> ProcessActions {
        ProcessActions(
            canControl: { canControl($0, uid: uid, owner: owner) },
            quit: { target in
                switch gate(target, uid: uid, owner: owner, startTime: startTime) {
                case .notPermitted: .notPermitted
                case .exited: .exited
                case .proceed(let live): await signal(live, force: false, startTime: startTime, quitWait: quitWait)
                }
            },
            forceQuit: { target in
                switch gate(target, uid: uid, owner: owner, startTime: startTime) {
                case .notPermitted: .notPermitted
                case .exited: .exited
                case .proceed(let live): await signal(live, force: true, startTime: startTime, quitWait: quitWait)
                }
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

    /// Pure rule (unit-tested): non-empty, no synthetic (< 0) or kernel/launchd (≤ 1) pid, not Telltale itself,
    /// every owner == uid.
    public static func canControl(_ t: ProcessTarget, uid: uid_t, owner: (Int32) -> uid_t?,
                                  ownPID: Int32 = getpid(),
                                  ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        let p = t.pids
        guard !p.isEmpty, p.allSatisfy({ $0 > 1 }), !t.isSelf(ownPID: ownPID, ownBundleID: ownBundleID) else {
            return false
        }
        if case .process(_, _, _, let declared) = t, declared != uid { return false }
        return p.allSatisfy { owner($0) == uid }
    }

    enum Gate: Equatable {
        /// Act on this target, reduced to its still-running members.
        case proceed(ProcessTarget)
        case exited
        case notPermitted
    }

    /// Action gate: the static rules (no synthetic/launchd pid, not Telltale, declared uid) apply to the whole
    /// target; members that have exited (start time no longer matches) are dropped first, so a helper that quit
    /// while the confirm dialog was open never blocks the action; none left → `.exited`. The owner check runs on
    /// the live members only (a member that exits during the check is dropped too).
    static func gate(_ t: ProcessTarget, uid: uid_t, owner: (Int32) -> uid_t?, startTime: (Int32) -> UInt64?,
                     ownPID: Int32 = getpid(), ownBundleID: String? = Bundle.main.bundleIdentifier) -> Gate {
        let p = t.pids
        guard !p.isEmpty, p.allSatisfy({ $0 > 1 }), !t.isSelf(ownPID: ownPID, ownBundleID: ownBundleID) else {
            return .notPermitted
        }
        if case .process(_, _, _, let declared) = t, declared != uid { return .notPermitted }
        var live = t.processIDs.filter { isAlive($0, startTime: startTime) }
        guard !live.isEmpty else { return .exited }
        for id in live where owner(id.pid) != uid {
            if isAlive(id, startTime: startTime) { return .notPermitted }       // another user's live process
        }
        live = live.filter { owner($0.pid) == uid && isAlive($0, startTime: startTime) }
        guard !live.isEmpty else { return .exited }
        switch t {
        case .app(let identity, _): return .proceed(.app(identity, processes: live))
        case .process: return .proceed(t)
        }
    }

    /// Who receives the signal (pure, unit-tested; see the type comment for the rule).
    static func recipients(_ t: ProcessTarget, force: Bool, isRegularApp: (Int32) -> Bool) -> [ProcessID] {
        switch t {
        case .process(let id, _, _, _):
            return [id]
        case .app(_, let ids):
            if force { return ids }
            let apps = ids.filter { isRegularApp($0.pid) }
            if !apps.isEmpty { return apps }
            return leader(of: ids).map { [$0] } ?? []
        }
    }

    /// Group leader of a bundle-less group: the earliest-started member (the responsible process spawns the others).
    static func leader(of ids: [ProcessID]) -> ProcessID? {
        let known = ids.filter { $0.startTimeUs != 0 }
        return known.min { ($0.startTimeUs, $0.pid) < ($1.startTimeUs, $1.pid) } ?? ids.first
    }

    /// Same process still running: the pid's current start time equals the stored one. An unknown stored start
    /// time (0) can't be verified and counts as exited, so it is never signalled.
    static func isAlive(_ id: ProcessID, startTime: (Int32) -> UInt64?) -> Bool {
        id.startTimeUs != 0 && startTime(id.pid) == id.startTimeUs
    }

    @MainActor static func signal(_ t: ProcessTarget, force: Bool, startTime: @Sendable (Int32) -> UInt64?,
                                  quitWait: Duration) async -> ActionResult {
        let targets = recipients(t, force: force) { pid in
            NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy != .prohibited } ?? false
        }
        var sent: [ProcessID] = []
        var failures: [String] = []
        for id in targets {
            guard isAlive(id, startTime: startTime) else { continue }       // exited or pid reused: no signal
            if let app = NSRunningApplication(processIdentifier: id.pid) {
                if force ? app.forceTerminate() : app.terminate() {
                    sent.append(id)
                    continue
                }                                                            // app refused (e.g. already quitting)
                guard isAlive(id, startTime: startTime) else { continue }
            }
            if kill(id.pid, force ? SIGKILL : SIGTERM) == 0 || errno == ESRCH {
                sent.append(id)
            } else {
                failures.append("\(id.pid): \(String(cString: strerror(errno)))")
            }
        }
        if !failures.isEmpty { return .failed(failures.joined(separator: ", ")) }
        if sent.isEmpty { return .exited }
        if force { return .done }
        return await waitUntilGone(sent, startTime: startTime, timeout: quitWait) ? .done : .requested
    }

    /// Polls (50 ms) until none of `ids` is alive, up to `timeout`.
    @MainActor static func waitUntilGone(_ ids: [ProcessID], startTime: @Sendable (Int32) -> UInt64?,
                                         timeout: Duration) async -> Bool {
        let end = ContinuousClock.now + timeout
        while true {
            if !ids.contains(where: { isAlive($0, startTime: startTime) }) { return true }
            guard ContinuousClock.now < end, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Effective owner uid of a live pid (`KERN_PROC_PID`); nil if gone.
    @Sendable public static func ownerUID(_ pid: Int32) -> uid_t? {
        guard let info = kinfo(pid) else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// Kernel start time (µs since epoch) of a running pid; nil when it is gone or a zombie (exited, not reaped).
    @Sendable public static func liveStartTimeUs(_ pid: Int32) -> UInt64? {
        guard let info = kinfo(pid), Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return UInt64(max(0, t.tv_sec)) * 1_000_000 + UInt64(max(0, t.tv_usec))
    }

    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
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
        case .app(let identity, let ids):
            if let b = identity.bundlePath { return URL(fileURLWithPath: b) }
            return ids.lazy.compactMap { NSRunningApplication(processIdentifier: $0.pid)?.bundleURL }.first
        case .process(let id, _, let path, _):
            if let path { return URL(fileURLWithPath: path) }
            return NSRunningApplication(processIdentifier: id.pid)?.executableURL
        }
    }
}
