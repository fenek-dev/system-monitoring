import ClipboardCore
import Foundation

/// In-memory history for renders, tests and `--mock` (the picker never reads the clipboard or the disk there).
public enum ClipboardFixture {
    public static func items(now: Date) -> [ClipItem] {
        func text(_ id: Int64, _ value: String, app: String, bundle: String, ago: TimeInterval,
                  pinned: Bool = false) -> ClipItem {
            ClipItem(id: id, kind: .text, text: value, textLength: value.count, byteSize: Int64(value.utf8.count),
                     hash: "fixture-\(id)", sourceBundleID: bundle, sourceName: app,
                     createdAt: now.addingTimeInterval(-ago), lastUsedAt: now.addingTimeInterval(-ago), pinned: pinned)
        }
        func files(_ id: Int64, _ paths: [String], ago: TimeInterval) -> ClipItem {
            ClipItem(id: id, kind: .files, files: paths, hash: "fixture-\(id)", sourceBundleID: "com.apple.finder",
                     sourceName: "Finder", createdAt: now.addingTimeInterval(-ago),
                     lastUsedAt: now.addingTimeInterval(-ago))
        }
        let minute: TimeInterval = 60
        let hour = 60 * minute
        let day = 24 * hour
        return [
            text(1, "ssh deploy@build-01.internal -p 2222", app: "Terminal", bundle: "com.apple.Terminal",
                 ago: 3 * day, pinned: true),
            text(2, "support@warden.dev", app: "Safari", bundle: "com.apple.Safari", ago: 6 * day, pinned: true),
            text(3, "let snapshot = try await store.items()", app: "Xcode", bundle: "com.apple.dt.Xcode", ago: 20),
            text(4, "https://developer.apple.com/documentation/swiftui/focusstate", app: "Safari",
                 bundle: "com.apple.Safari", ago: 4 * minute),
            text(5, "git status\ngit diff --stat\ngit commit -m \"Fix paste\"", app: "Terminal",
                 bundle: "com.apple.Terminal", ago: 12 * minute),
            ClipItem(id: 6, kind: .image, imageFile: "fixture-6.png", imageWidth: 1280, imageHeight: 720,
                     byteSize: 412_000, hash: "fixture-6", sourceBundleID: "com.figma.Desktop", sourceName: "Figma",
                     createdAt: now.addingTimeInterval(-35 * minute), lastUsedAt: now.addingTimeInterval(-35 * minute)),
            files(7, ["/Users/me/Documents/Invoice-2026-09.pdf"], ago: 2 * hour),
            files(8, ["/Users/me/Documents/Q3 report.xlsx", "/Users/me/Documents/Q3 summary.pdf",
                      "/Users/me/Desktop/chart.png"], ago: 3 * hour),
            text(9, "The quick brown fox jumps over the lazy dog while the build server compiles every target in "
                 + "release mode and nobody is watching the progress bar crawl across the screen", app: "Xcode",
                 bundle: "com.apple.dt.Xcode", ago: 5 * hour),
            text(10, "Warden 0.1.0 release notes", app: "Safari", bundle: "com.apple.Safari", ago: 26 * hour),
            text(11, "#0A84FF", app: "Figma", bundle: "com.figma.Desktop", ago: 2 * day),
            text(12, "brew install swiftlint", app: "Terminal", bundle: "com.apple.Terminal", ago: 9 * day),
        ]
    }
}
