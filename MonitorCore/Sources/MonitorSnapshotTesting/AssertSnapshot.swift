import Foundation
import MonitorUIKit
import SnapshotProcessSetup
import SwiftUI
import Testing

/// Snapshot assertion (ARCHITECTURE §8). Test-only target: never linked by the app.
///
/// - Golden: `<dir of the calling test file>/__Snapshots__/<named>.png`.
/// - `TELLTALE_RECORD=1` rewrites goldens (the test passes). Locally a missing golden is written and reported once.
/// - Strict mode (`CI` set or `TT_SNAPSHOT_STRICT=1`, exported by scripts/ci.sh): a missing golden fails without
///   writing anything, and recording is refused.
/// - A renderer failure always fails (never skipped).
/// - Compare: fraction of pixels with any channel Δ > 8/255 must be ≤ `tolerance`.
/// - Failures write `<package>/.build/snapshot-failures/<named>.{actual,golden,diff}.png`.
@MainActor public func assertSnapshot<V: View>(_ view: V, size: CGSize, named: String, path: SnapshotRenderer.Path = .hosting,
                                               tolerance: Double = 0.005, sourceLocation: SourceLocation = #_sourceLocation) {
    let env = ProcessInfo.processInfo.environment
    verifySnapshot(view, size: size, named: named, path: path, tolerance: tolerance,
                   record: env["TELLTALE_RECORD"] == "1", strict: SnapshotMode.isStrict(env), sourceLocation: sourceLocation)
}

enum SnapshotMode {
    static func isStrict(_ env: [String: String]) -> Bool {
        env["CI"] != nil || env["TT_SNAPSHOT_STRICT"] == "1"
    }
}

/// `assertSnapshot` with explicit record/strict flags (tests of the harness itself).
@MainActor func verifySnapshot<V: View>(_ view: V, size: CGSize, named: String, path: SnapshotRenderer.Path,
                                        tolerance: Double, record: Bool, strict: Bool = false,
                                        sourceLocation: SourceLocation) {
    // Font smoothing latches at the process's first text layout, so it must be off before any test runs.
    guard tt_snapshot_text_rendering_configured_at_load() else {
        Issue.record("snapshot \(named): SnapshotProcessSetup constructor did not run (font smoothing not fixed)",
                     sourceLocation: sourceLocation)
        return
    }
    guard let actual = SnapshotRenderer.render(view, size: size, path: path) else {
        Issue.record("snapshot \(named): renderer unavailable / render failed", sourceLocation: sourceLocation)
        return
    }
    let testFile = URL(fileURLWithPath: sourceLocation.filePath)
    let golden = testFile.deletingLastPathComponent().appendingPathComponent("__Snapshots__/\(named).png")
    let missing = !FileManager.default.fileExists(atPath: golden.path)

    if strict && (record || missing) {
        Issue.record(record ? "snapshot \(named): TELLTALE_RECORD is not allowed in strict (CI) mode"
                            : "snapshot \(named): no golden \(golden.lastPathComponent) (strict mode: not recorded)",
                     sourceLocation: sourceLocation)
        return
    }

    if record || missing {
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
