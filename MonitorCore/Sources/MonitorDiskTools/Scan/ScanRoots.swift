import Darwin
import Foundation
import MonitorModel

/// Whether the app can read TCC-protected locations (spec §5.7). Without it the scan still runs, but Mail, Safari,
/// Messages and similar data show up as restricted nodes.
public enum FullDiskAccessProbe {
    /// Opens `~/Library/Safari`, which only exists for users with Safari data and is protected by Full Disk Access:
    /// `EPERM`/`EACCES` → not granted. A missing folder or any other failure gives no evidence of a denial, so it
    /// reads as granted (the banner would otherwise nag users who never used Safari).
    public static func check(home: String) -> Bool {
        status(home: home) != .denied
    }

    public enum Status: Sendable, Equatable {
        case granted, denied
        /// The probe folder is missing or failed for another reason: no evidence either way.
        case inconclusive
    }

    public static func status(home: String) -> Status {
        let path = home + "/Library/Safari"
        do {
            _ = try FileDescriptor.open(at: AT_FDCWD, path, flags: O_RDONLY | O_DIRECTORY)
            return .granted
        } catch {
            switch error.errno {
            case EPERM, EACCES:
                return .denied
            case ENOENT:
                DiskTools.log.info("FDA probe: \(path) does not exist")
                return .inconclusive
            default:
                DiskTools.log.error("FDA probe: open \(path) failed, errno \(error.errno ?? 0)")
                return .inconclusive
            }
        }
    }
}

/// Whether the scan may trigger macOS consent prompts. A prompt blocks the opening thread until someone answers it,
/// so an unattended run (CLI, tests) must never allow them.
public enum PromptMode: Sendable, Equatable {
    /// GUI app: one-time consents for Desktop, Documents, Downloads, iCloud and chosen volumes may appear.
    case allow
    /// Every location that could prompt is recorded as restricted and never opened.
    case never
}

/// What the scan may open, as data: path rules (see `WalkRules.blocks`) switched by these fields. Without a
/// *confirmed* Full Disk Access grant, other apps' containers and sensitive category folders are never opened;
/// with `promptMode == .never` the prompting locations are closed as well. Closed locations become restricted
/// nodes (size unknown) instead of being listed.
public struct ScanAccessPolicy: Sendable, Equatable {
    public var fullDiskAccess: Bool
    /// Container names containing one of these belong to this app and are always readable.
    public var ownBundleMarkers: [String]
    public var promptMode: PromptMode

    public init(fullDiskAccess: Bool, ownBundleMarkers: [String] = ["dev.warden", "dev.telltale"],
                promptMode: PromptMode = .allow) {
        self.fullDiskAccess = fullDiskAccess
        self.ownBundleMarkers = ownBundleMarkers
        self.promptMode = promptMode
    }

    /// Probes now; an inconclusive probe counts as not granted.
    public static func detect(home: String, promptMode: PromptMode = .allow) -> ScanAccessPolicy {
        ScanAccessPolicy(fullDiskAccess: FullDiskAccessProbe.status(home: home) == .granted, promptMode: promptMode)
    }

    func isOwnContainer(_ name: String) -> Bool {
        ownBundleMarkers.contains { name.contains($0) }
    }
}

public enum ScanRoots {
    /// Home first, then every mounted volume the user can browse (system plumbing and snapshots left out).
    public static func available() -> [ScanRoot] {
        var roots: [ScanRoot] = [.home(NSHomeDirectory())]
        // The Data volume is flagged DONTBROWSE like system plumbing, but it is the user's "Macintosh HD".
        for mount in mounts() where !isHidden(flags: mount.flags) || mount.path == "/System/Volumes/Data" {
            let name = mount.path == "/System/Volumes/Data"
                ? "Macintosh HD"
                : (mount.path.split(separator: "/").last.map(String.init) ?? mount.path)
            roots.append(.volume(path: mount.path, name: name))
        }
        return roots
    }

    static func isHidden(flags: UInt32) -> Bool {
        flags & UInt32(MNT_DONTBROWSE) != 0 || flags & UInt32(MNT_SNAPSHOT) != 0
    }

    private static func mounts() -> [(path: String, flags: UInt32)] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else {
            DiskTools.log.error("getfsstat count failed, errno \(Darwin.errno)")
            return []
        }
        var failedErrno: Int32 = 0
        let buffer: [statfs] = .init(unsafeUninitializedCapacity: Int(count)) { storage, initialized in
            let size = Int32(MemoryLayout<statfs>.stride * storage.count)
            let filled = getfsstat(storage.baseAddress, size, MNT_NOWAIT)
            if filled < 0 { failedErrno = Darwin.errno }
            initialized = Int(max(filled, 0))
        }
        guard failedErrno == 0 else {
            DiskTools.log.error("getfsstat failed, errno \(failedErrno)")
            return []
        }
        return buffer.map { entry in
            var name = entry.f_mntonname
            let path = withUnsafePointer(to: &name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return (path, entry.f_flags)
        }
    }
}
