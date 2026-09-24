import Foundation
import MonitorUIKit
import SwiftUI
import Testing

/// Snapshot assertion (ARCHITECTURE §8). Test-only target: never linked by the app.
///
/// - Golden: `<dir of the calling test file>/__Snapshots__/<named>.png`.
/// - `TELLTALE_RECORD=1` rewrites goldens (the test passes). A missing golden is written and reported as an issue.
/// - Compare: fraction of pixels with any channel Δ > 8/255 must be ≤ `tolerance`.
/// - Failures write `<package>/.build/snapshot-failures/<named>.{actual,golden,diff}.png`.
@MainActor public func assertSnapshot<V: View>(_ view: V, size: CGSize, named: String, path: SnapshotRenderer.Path = .hosting,
                                               tolerance: Double = 0.005, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let actual = SnapshotRenderer.render(view, size: size, path: path) else {
        Issue.record("snapshot \(named): render failed", sourceLocation: sourceLocation)
        return
    }
    let testFile = URL(fileURLWithPath: sourceLocation.filePath)
    let golden = testFile.deletingLastPathComponent().appendingPathComponent("__Snapshots__/\(named).png")
    let record = ProcessInfo.processInfo.environment["TELLTALE_RECORD"] == "1"

    if record || !FileManager.default.fileExists(atPath: golden.path) {
        do {
            try SnapshotRenderer.writePNG(actual, to: golden)
        } catch {
            Issue.record("snapshot \(named): cannot write golden: \(error)", sourceLocation: sourceLocation)
            return
        }
        if !record {
            Issue.record("snapshot \(named): no golden; recorded \(golden.lastPathComponent) — review and rerun",
                         sourceLocation: sourceLocation)
        }
        return
    }

    guard let expected = SnapshotRenderer.readPNG(golden).flatMap(SnapshotImage.normalized) else {
        Issue.record("snapshot \(named): unreadable golden", sourceLocation: sourceLocation)
        return
    }
    let diff = SnapshotImage.compare(expected, actual)
    guard diff.sizeMismatch || diff.fraction > tolerance else { return }

    let failures = SnapshotFailures.directory(from: testFile)
    try? SnapshotRenderer.writePNG(actual, to: failures.appendingPathComponent("\(named).actual.png"))
    try? SnapshotRenderer.writePNG(expected, to: failures.appendingPathComponent("\(named).golden.png"))
    if let d = diff.diffImage {
        try? SnapshotRenderer.writePNG(d, to: failures.appendingPathComponent("\(named).diff.png"))
    }
    let what = diff.sizeMismatch
        ? "size \(actual.width)×\(actual.height) ≠ golden \(expected.width)×\(expected.height)"
        : String(format: "%.3f%% pixels differ (tolerance %.3f%%)", diff.fraction * 100, tolerance * 100)
    Issue.record("snapshot \(named): \(what); artifacts in \(failures.path)", sourceLocation: sourceLocation)
}

enum SnapshotFailures {
    /// `<package root>/.build/snapshot-failures`, where the package root is the nearest ancestor with Package.swift.
    static func directory(from testFile: URL) -> URL {
        var dir = testFile.deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.appendingPathComponent(".build/snapshot-failures")
            }
            dir = dir.deletingLastPathComponent()
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-failures")
    }
}
