import Foundation
@testable import MonitorScreens
import Testing

/// A-M1 ruling: one instance per data dir (`flock`), released when the holder goes away.
@Suite("Shell single instance (ShellSingleInstanceTests)")
struct ShellSingleInstanceTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tt-instance-\(UUID().uuidString)")
    }

    @Test func secondLaunchOnTheSameDataDirIsRefusedUntilTheFirstExits() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let first = InstanceLock.acquire(dataDirectory: dir)
            guard case .acquired = first else { Issue.record("first acquire failed"); return }
            guard case .heldByAnotherInstance = InstanceLock.acquire(dataDirectory: dir) else {
                Issue.record("second acquire should be refused"); return
            }
            withExtendedLifetime(first) {}
        }                                                               // holder gone → lock released
        guard case .acquired = InstanceLock.acquire(dataDirectory: dir) else {
            Issue.record("acquire after release failed"); return
        }
    }

    @Test func otherDataDirsRunSideBySide() {
        let a = tempDir(), b = tempDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let la = InstanceLock.acquire(dataDirectory: a), lb = InstanceLock.acquire(dataDirectory: b)
        guard case .acquired = la, case .acquired = lb else { Issue.record("both should acquire"); return }
    }

    @Test func activationKeyIsTheResolvedDataDirPath() throws {
        let dir = tempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dotted = dir.appendingPathComponent("sub/..", isDirectory: true)
        #expect(InstanceActivation.key(dotted) == InstanceActivation.key(dir))
    }
}
