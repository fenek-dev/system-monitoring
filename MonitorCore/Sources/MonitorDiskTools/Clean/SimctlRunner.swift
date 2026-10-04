import Foundation
import Synchronization

public enum SimctlResult: Equatable, Sendable {
    case success
    case failed(String)
}

/// Runs `xcrun simctl delete unavailable`. The only way unavailable simulators are removed: their directory is
/// never touched by path.
public protocol SimctlRunner: Sendable {
    func deleteUnavailable() -> SimctlResult
}

public struct ProcessSimctlRunner: SimctlRunner {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func deleteUnavailable() -> SimctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "delete", "unavailable"]
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch {
            return .failed("launch: \(error.localizedDescription)")
        }
        // Drain stderr while waiting so a chatty child can't block on a full pipe.
        let output = Mutex(Data())
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            output.withLock { $0.append(chunk) }
        }
        defer { stderr.fileHandleForReading.readabilityHandler = nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            return .failed("timeout")
        }
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output.withLock { $0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed("exit \(process.terminationStatus)" + (text.isEmpty ? "" : ": \(text)"))
        }
        return .success
    }
}
