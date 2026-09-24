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
}
