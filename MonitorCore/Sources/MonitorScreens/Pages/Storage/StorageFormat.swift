import Foundation
import MonitorModel
import MonitorUIKit
import SwiftUI

/// Which Storage view the page opens in; the catalog sets it through the environment because pages are built
/// from `init()` by `DashboardRoot`.
public enum StorageMode: Hashable, Sendable { case spaceMap, cleanup }

public extension EnvironmentValues {
    @Entry var storageInitialMode: StorageMode = .spaceMap
}

/// Shared Storage strings (DESIGN §3.17, §5.8). Pure functions: nothing here reads the clock.
public enum StorageFormat {
    public static let estimateTooltip = "Estimate. Files that share storage with clones may free more when deleted together."

    /// "≈" when the size is not exact (clones may free more); unavailable or missing → "—".
    public static func bytes(_ b: UInt64?, provenance: SizeProvenance,
                             style: TTFormat.StorageStyle = .headline) -> String {
        guard let b, provenance != .unavailable else { return TTFormat.unavailable }
        let text = TTFormat.storage(b, style: style)
        return provenance == .exact ? text : "≈" + text
    }

    /// "Scanned just now" / "Scanned 5 min ago" / "Scanned 3 h ago" / "Scanned 2 d ago"; a week or older → "Scanned 24 Sep".
    public static func scannedAgo(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Scanned just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Scanned \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Scanned \(hours) h ago" }
        let days = hours / 24
        if days < 7 { return "Scanned \(days) d ago" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return "Scanned " + formatter.string(from: date)
    }

    /// "Selected ≈14.2 GB · 37 items".
    public static func selection(bytes b: UInt64?, provenance: SizeProvenance, count: Int) -> String {
        "Selected \(bytes(b, provenance: provenance)) · \(count) \(count == 1 ? "item" : "items")"
    }
}
