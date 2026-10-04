import Foundation
import Synchronization

enum ProcessRunError: Error, Equatable {
    case launchFailed(String)
    case timedOut
}

/// One short-lived child process for the classifier's probes (`mdfind`, `git`, `xcode-select`, `simctl`). Output is
/// drained concurrently (a full pipe would otherwise stall the child) and capped at `outputLimit` bytes.
enum ProcessRun {
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
    }

    private final class Collected: Sendable {
        let data = Mutex(Data())
    }

    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                    timeout: TimeInterval, outputLimit: Int = 4 << 20) throws(ProcessRunError) -> Output {
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
        do {
            try process.run()
        } catch {
            throw .launchFailed("\(executable): \(error.localizedDescription)")
        }

        let collected = Collected()
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                collected.data.withLock { data in
                    if data.count < outputLimit { data.append(chunk.prefix(outputLimit - data.count)) }
                }
            }
            drained.signal()
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            exited.wait()
        }
        // The pipe reaches EOF once the child (and anything it forked holding the pipe) is gone.
        drained.wait()
        if timedOut { throw .timedOut }
        return Output(status: process.terminationStatus, stdout: collected.data.withLock { $0 })
    }
}
