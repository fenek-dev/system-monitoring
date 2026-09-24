import AppKit
import Darwin
import Foundation
import SwiftUI

/// Result of a [Sample] run.
public enum ProcessSampleResult: Equatable, Sendable {
    case done(URL)
    case failed(String)
}

/// Injected [Sample] service (DESIGN §3.12 item 4, §6.23 "kept as design"; the ARCHITECTURE "Sample dropped" note is
/// superseded by the design-match ruling). Tests inject a stub, so nothing is spawned.
public protocol ProcessSampling: Sendable {
    /// Kernel start time (µs since epoch, `kinfo_proc.p_starttime`) of `pid`, nil if there is no such process.
    /// Checked right before spawning so a reused pid is never sampled.
    func startTimeUs(pid: Int32) -> UInt64?
    /// Samples `pid` for 3 s into a fresh report file; off the main thread; bounded by a timeout.
    func sample(pid: Int32, name: String) async -> ProcessSampleResult
    /// Shows the report (Finder).
    @MainActor func reveal(_ url: URL)
}

/// `/usr/bin/sample <pid> 3 -file <unique dir>/Telltale-<name>-<pid>-<uuid8>.txt` on a detached utility task.
/// - The report goes to a fresh per-run directory from `FileManager.url(for: .itemReplacementDirectory, …)` (0700,
///   unique), so a leftover or planted file is never trusted.
/// - Success needs exit 0 and a regular file (lstat: not a symlink) modified after the spawn.
/// - Timeout: SIGTERM after `timeout` (15 s), SIGKILL 2 s later; reported as a failure.
public struct LiveProcessSampler: ProcessSampling {
    public var executable: URL
    public var timeout: TimeInterval
    /// Arguments for (pid, report path); `sample`'s by default. Tests swap the executable (e.g. `/bin/sleep`).
    public var arguments: @Sendable (Int32, String) -> [String]

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/sample"), timeout: TimeInterval = 15,
                arguments: @escaping @Sendable (Int32, String) -> [String] = { [String($0), "3", "-file", $1] }) {
        self.executable = executable
        self.timeout = timeout
        self.arguments = arguments
    }

    public nonisolated static func reportName(pid: Int32, name: String, token: String = UUID().uuidString) -> String {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(60))
        return "Telltale-\(safe.isEmpty ? "process" : safe)-\(pid)-\(token.prefix(8)).txt"
    }

    public func startTimeUs(pid: Int32) -> UInt64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return UInt64(max(0, t.tv_sec)) * 1_000_000 + UInt64(max(0, t.tv_usec))
    }

    public func sample(pid: Int32, name: String) async -> ProcessSampleResult {
        let executable = executable, timeout = timeout, arguments = arguments
        // `run` blocks for 3–19 s; keep it on GCD, never on a cooperative-pool thread.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.run(executable: executable, timeout: timeout,
                                                        arguments: arguments, pid: pid, name: name))
            }
        }
    }

    /// Blocking body (runs on a GCD utility queue).
    nonisolated static func run(executable: URL, timeout: TimeInterval,
                                arguments: @Sendable (Int32, String) -> [String], pid: Int32,
                                name: String) -> ProcessSampleResult {
            let fm = FileManager.default
            let dir: URL
            do {
                dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: fm.temporaryDirectory, create: true)
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            } catch {
                return .failed(error.localizedDescription)
            }
            let url = dir.appendingPathComponent(Self.reportName(pid: pid, name: name))
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments(pid, url.path)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            let spawned = Date()
            do {
                try process.run()
            } catch {
                return .failed(error.localizedDescription)
            }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()                                          // SIGTERM
                if exited.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = exited.wait(timeout: .now() + 2)
                }
                return .failed("sample timed out after \(String(format: "%g", timeout)) s")
            }
            guard process.terminationStatus == 0 else {
                return .failed("sample exited with status \(process.terminationStatus)")
            }
            guard Self.isFreshRegularFile(url.path, notBefore: spawned) else {
                return .failed("no report was written")
            }
            return .done(url)
    }

    /// lstat: exists, a regular file (a symlink fails), modified at or after `notBefore` (1-s tolerance).
    public nonisolated static func isFreshRegularFile(_ path: String, notBefore: Date) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return false }
        let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return modified >= notBefore.timeIntervalSince1970 - 1
    }

    @MainActor public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension EnvironmentValues {
    /// [Sample] runner (default: `/usr/bin/sample`); tests inject a stub.
    @Entry var processSampler: any ProcessSampling = LiveProcessSampler()
}
