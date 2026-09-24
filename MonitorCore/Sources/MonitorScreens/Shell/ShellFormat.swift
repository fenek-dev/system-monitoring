import Foundation
import MonitorModel
import MonitorUIKit

/// Values the shell shows that pages show too. One function each, so both read the same field with the same rule.
public enum ShellFormat {
    /// Free space of a volume (ruling CP2): available capacity `VolumeInfo.availableBytes` (statfs available /
    /// container free = diskutil; purgeable is separate, not included), decimal units, DESIGN §5.3 capacity rule:
    /// integer GB under 1 TB ("382 GB"), 2-decimal TB with trailing zeros trimmed above ("1.09 TB").
    /// Nil volume → "—". Used by the sidebar ("382 GB free") and the Disk page's Free space stat.
    public static func freeSpace(_ volume: VolumeInfo?) -> String {
        TTFormat.storage(volume?.availableBytes, style: .capacity)
    }

    /// Short model name for the sidebar footer (DESIGN §3.0 "MacBook Pro 14″"), from IODeviceTree `product-name`:
    /// "MacBook Pro (14-inch, 2021)" → "MacBook Pro 14″", "iMac (24-inch, 2023)" → "iMac 24″",
    /// "Mac mini (2023)" → "Mac mini", "MacBook Air (M1, 2020)" → "MacBook Air". Unknown families: the raw string.
    public static func modelShortName(_ raw: String) -> String {
        let families = ["MacBook Pro", "MacBook Air", "MacBook", "Mac mini", "Mac Studio", "Mac Pro", "iMac"]
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let family = families.first(where: { trimmed == $0 || trimmed.hasPrefix($0 + " (") }) else { return raw }
        let rest = trimmed.dropFirst(family.count)
        guard let inch = rest.firstMatch(of: /(\d+(?:\.\d+)?)-inch/) else { return family }
        return "\(family) \(inch.1)″"
    }
}
