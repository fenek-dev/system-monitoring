import Darwin
import Foundation
import Synchronization

enum ProcessRunError: Error, Equatable {
    case launchFailed(String)
    case timedOut
}

/// One short-lived child process for the classifier's probes (`mdfind`, `git`, `xcode-select`, `simctl`). Output is
/// drained concurrently (a full pipe would otherwise stall the child) and capped at `outputLimit` bytes. Every wait
/// is bounded: a child ignoring SIGTERM is killed after `grace`, and a grandchild that inherited stdout cannot hold
/// the call past `grace` after the child exits.
enum ProcessRun {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
    }

    private final class Collected: Sendable {
        let data = Mutex(Data())
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                    timeout: TimeInterval, grace: TimeInterval = 2,
                    outputLimit: Int = 4 << 20) throws(ProcessRunError) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Dispatch-source driven, so no thread sits blocked in `read` when a stray holder keeps the pipe open.
        let collected = Collected()
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
                return
            }
            collected.data.withLock { data in
                if data.count < outputLimit { data.append(chunk.prefix(outputLimit - data.count)) }
            }
        }
        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            throw .launchFailed("\(executable): \(error.localizedDescription)")
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + grace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + grace)
            }
        }
        if drained.wait(timeout: .now() + (timedOut ? 0 : grace)) == .timedOut {
            // A grandchild still holds the pipe: keep what arrived, stop listening.
            reader.readabilityHandler = nil
        }
        if timedOut { throw .timedOut }
        return Output(status: process.terminationStatus, stdout: collected.data.withLock { $0 })
    }
}
