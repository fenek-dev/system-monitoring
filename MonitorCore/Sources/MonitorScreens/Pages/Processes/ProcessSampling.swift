import AppKit
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
    /// Samples `pid` for 3 s into a report file; off the main thread.
    func sample(pid: Int32, name: String) async -> ProcessSampleResult
    /// Shows the report (Finder).
    @MainActor func reveal(_ url: URL)
}

/// `/usr/bin/sample <pid> 3 -file <tmp>/Telltale-<name>-<pid>.txt`, run on a detached utility task; success when
/// it exits 0 and wrote the file. Reveal selects the file in Finder.
public struct LiveProcessSampler: ProcessSampling {
    public init() {}

    public nonisolated static func reportURL(pid: Int32, name: String,
                                             directory: URL = FileManager.default.temporaryDirectory) -> URL {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(60))
        return directory.appendingPathComponent("Telltale-\(safe.isEmpty ? "process" : safe)-\(pid).txt")
    }

    public func sample(pid: Int32, name: String) async -> ProcessSampleResult {
        let url = Self.reportURL(pid: pid, name: name)
        return await Task.detached(priority: .utility) { () -> ProcessSampleResult in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(pid), "3", "-file", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .failed(error.localizedDescription)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
                return .failed("sample exited with status \(process.terminationStatus)")
            }
            return .done(url)
        }.value
    }

    @MainActor public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension EnvironmentValues {
    /// [Sample] runner (default: `/usr/bin/sample`); tests inject a stub.
    @Entry var processSampler: any ProcessSampling = LiveProcessSampler()
}
