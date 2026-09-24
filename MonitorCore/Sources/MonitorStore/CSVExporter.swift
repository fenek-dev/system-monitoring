import Foundation
import GRDB
import MonitorModel

/// `time,<HistoryMetric.allCases…>` at the range's storage level (raw rows for Live/1H/24H, 1 m averages for 7D,
/// 15 m for 30D; plus the not-yet-rolled raw tail). ISO-8601 UTC, empty cell = missing. Streamed via a cursor
/// in 64 KB chunks. Per-app rows are not exported.
/// Written to a temporary sibling file that replaces `url` only once complete, so a failure mid-write leaves an
/// existing file untouched.
enum CSVExporter {
    static let chunkBytes = 64 * 1_024

    static func export(_ db: Database, level: Level, window: Window, to url: URL) throws -> ExportSummary {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            let (rows, bytes) = try write(db, level: level, window: window, to: temp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
            return ExportSummary(rows: rows, bytes: bytes, url: url)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    private static func write(_ db: Database, level: Level, window: Window, to url: URL) throws -> (rows: Int, bytes: Int) {
        let metrics = HistoryMetric.allCases.map(\.rawValue)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var buffer = (["time"] + metrics).joined(separator: ",") + "\n"
        var bytes = 0
        var rows = 0
        func drain() throws {
            let data = Data(buffer.utf8)
            try handle.write(contentsOf: data)
            bytes += data.count
            buffer.removeAll(keepingCapacity: true)
        }

        let source = try Queries.systemSource(db, level: level, cols: metrics, window: window)
        let cursor = try Row.fetchCursor(db, sql: "SELECT * FROM (\(source.sql)) ORDER BY ts", arguments: source.arguments)
        let style = Date.ISO8601FormatStyle()
        while let row = try cursor.next() {
            let ts: Int64 = row["ts"]
            buffer += Date(unixMs: ts).formatted(style)
            for (i, _) in metrics.enumerated() {
                buffer += ","
                if let v = Queries.finite(row[i + 3]) { buffer += String(describing: v) }   // ts, n, interval_ms first
            }
            buffer += "\n"
            rows += 1
            if buffer.utf8.count >= chunkBytes { try drain() }
        }
        try drain()
        return (rows, bytes)
    }
}
