import AppKit
import MonitorModel
import SwiftUI

/// sRGB color from a 0xRRGGBB literal (DESIGN §1.1 writes every token as hex).
public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

public extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// DESIGN §1.1. Alpha tokens are written exactly as listed (never pre-blended).
public enum TTColor {
    // MARK: Backgrounds
    public static let bgWindow = Color(hex: 0x1B1B1D)
    public static let bgHeader = Color(hex: 0x202023)
    public static let bgCard = Color(hex: 0x232326)
    public static let bgSidebar = Color(hex: 0x242427)
    public static let bgPopover = Color(hex: 0x28282C, opacity: 0.97)
    public static let bgElevated = Color(hex: 0x2C2C30)
    public static let bgScrim = Color.black.opacity(0.45)

    // MARK: Text
    public static let textPrimary = Color(hex: 0xF2F2F4)
    public static let textSecondary = Color(hex: 0xA8A8B0)
    public static let textTertiary = Color(hex: 0x9A9AA2)
    public static let textOnAccent = Color(hex: 0xFFFFFF)
    public static let link = Color(hex: 0x6CB4FF)
    public static let linkHover = Color(hex: 0x9CCBFF)

    // MARK: Borders, dividers, fills
    public static let borderCard = Color.white.opacity(0.07)
    public static let borderWindow = Color.white.opacity(0.12)
    public static let borderPopover = Color.white.opacity(0.14)
    public static let borderControl = Color.white.opacity(0.08)
    public static let borderSwatch = Color.white.opacity(0.15)
    public static let separator = Color.white.opacity(0.08)
    public static let edgeSidebar = Color.black.opacity(0.50)
    public static let edgeHeader = Color.black.opacity(0.45)
    public static let fillTrack = Color.white.opacity(0.06)
    public static let fillField = Color.white.opacity(0.07)
    public static let fillZebra = Color.white.opacity(0.025)
    public static let fillHover = Color.white.opacity(0.05)
    public static let fillSelectedSidebar = Color.white.opacity(0.10)
    public static let fillSegmentOn = Color.white.opacity(0.18)
    public static let fillButton = Color.white.opacity(0.10)
    public static let fillButtonHover = Color.white.opacity(0.14)
    public static let fillIconButton = Color.white.opacity(0.08)
    public static let fillRest = Color.white.opacity(0.14)
    public static let fillFree = Color.white.opacity(0.08)
    public static let rowSelected = Color(hex: 0x0A84FF, opacity: 0.28)
    /// ADDED: popover row expanded background (§2.22).
    public static let fillExpanded = Color.white.opacity(0.06)
    /// Mirrored-chart center divider (§2.8).
    public static let chartDivider = Color.white.opacity(0.18)

    // MARK: Accent and actions
    public static let accent = Color(hex: 0x0A84FF)
    public static let destructive = Color(hex: 0xC9302C)

    // MARK: Category accents
    public static let cpu = Color(hex: 0x5EA8FF)
    public static let cpuAlt = Color(hex: 0x9CC9FF)
    public static let cpuLine = Color(hex: 0xCFE4FF)
    public static let gpu = Color(hex: 0xBF8CFF)
    public static let gpuAlt = Color(hex: 0xE6D7FF)
    public static let mem = Color(hex: 0x4FD1A5)
    public static let memWired = Color(hex: 0x2F9E7A)
    public static let memCompressed = Color(hex: 0xA7F0D4)
    public static let memCached = Color(hex: 0x4FD1A5, opacity: 0.28)
    public static let net = Color(hex: 0xFFA24C)
    public static let netUp = Color(hex: 0xFFD0A3)
    public static let thermal = Color(hex: 0xFF7A6B)
    public static let thermalGPU = Color(hex: 0xFFC2B8)
    public static let thermalBattery = Color(hex: 0xA8564D)
    public static let power = Color(hex: 0xFFD24C)
    public static let dram = Color(hex: 0x8E8E96)
    public static let disk = Color(hex: 0xF07AB8)
    public static let diskWrite = Color(hex: 0xFFC4E1)
    public static let diskPurgeable = Color(hex: 0xF07AB8, opacity: 0.35)
    public static let battery = Color(hex: 0x32D74B)

    // MARK: Status
    public static let statusCalm = Color(hex: 0x32D74B)
    public static let statusFair = Color(hex: 0xC8D64A)
    public static let statusElevated = Color(hex: 0xFFB340)
    public static let statusCritical = Color(hex: 0xFF453A)
    public static let statusElevatedRowFill = Color(hex: 0xFFB340, opacity: 0.12)
    public static let statusElevatedBannerFill = Color(hex: 0xFFB340, opacity: 0.14)
    public static let statusElevatedBannerBorder = Color(hex: 0xFFB340, opacity: 0.35)
    public static let statusElevatedSwatch = Color(hex: 0xFFB340, opacity: 0.50)
    public static let statusCriticalRowFill = Color(hex: 0xFF453A, opacity: 0.12)
    public static let statusCriticalBannerFill = Color(hex: 0xFF453A, opacity: 0.14)
    public static let statusCriticalBannerBorder = Color(hex: 0xFF453A, opacity: 0.35)
    public static let statusCriticalSwatch = Color(hex: 0xFF453A, opacity: 0.50)
    public static let statusPaused = Color(hex: 0x9A9AA2)

    // MARK: App letter tiles
    public static let tileHex: [UInt32] = [0x2F5FB3, 0x5B3FA8, 0x2A6F80, 0x8A4B2A, 0x3D6B35, 0x8C2F5A, 0x4D5260, 0x6B5A1F]
    public static let tiles: [Color] = tileHex.map { Color(hex: $0) }

    /// Stable tile index: FNV-1a (32-bit) of `key` mod 8 (§1.1).
    public static func tileIndex(for key: String) -> Int {
        var hash: UInt32 = 0x811C_9DC5
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return Int(hash % UInt32(tileHex.count))
    }

    public static func tile(for key: String) -> Color { tiles[tileIndex(for: key)] }

    // MARK: Lookups

    public static func category(_ c: MonitorModel.Category) -> Color {
        switch c {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: mem
        case .network: net
        case .thermals: thermal
        case .power: power
        case .disk: disk
        }
    }

    /// Alert level → status color (calm = `statusCalm`).
    public static func level(_ l: AlertLevel) -> Color {
        switch l {
        case .calm: statusCalm
        case .elevated: statusElevated
        case .critical: statusCritical
        }
    }

    /// Stressed popover row fill for a level (nil when calm).
    public static func rowFill(_ l: AlertLevel) -> Color? {
        switch l {
        case .calm: nil
        case .elevated: statusElevatedRowFill
        case .critical: statusCriticalRowFill
        }
    }

    public static func bannerFill(_ l: AlertLevel) -> Color {
        l == .critical ? statusCriticalBannerFill : statusElevatedBannerFill
    }

    public static func bannerBorder(_ l: AlertLevel) -> Color {
        l == .critical ? statusCriticalBannerBorder : statusElevatedBannerBorder
    }

    /// Treemap / app-metric color (§2.28).
    public static func metric(_ m: AppMetric) -> Color {
        switch m {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: mem
        case .netRx, .netTx: net
        case .diskRead, .diskWrite: disk
        case .energy: power
        }
    }
}

/// DESIGN §1.1 "Chart series fills": opacity applied to the series hex, plus line widths/dash per chart.
/// Components take these instead of hard-coding opacities.
public enum TTChartFill {
    /// Popover sparkline, Overview tile sparkline, History lanes.
    public static let sparkline: Double = 0.22
    /// Overview "Last 60 seconds" rows (and App detail rows).
    public static let timeline: Double = 0.18
    /// GPU utilization, Memory pressure.
    public static let gpuUtilization: Double = 0.25
    public static let memoryPressure: Double = 0.25
    /// ANE, Swap.
    public static let ane: Double = 0.20
    public static let swap: Double = 0.20
    /// Network ↓ / ↑.
    public static let netDown: Double = 0.30
    public static let netUp: Double = 0.25
    /// Disk read / write.
    public static let diskRead: Double = 0.30
    public static let diskWrite: Double = 0.25
    /// CPU Usage stacked: System (total) `cpuAlt`, User `cpu`, total outline `cpuLine` stroke opacity.
    public static let cpuSystem: Double = 0.35
    public static let cpuUser: Double = 0.55
    public static let cpuOutline: Double = 0.9
    /// Power stacked (no lines).
    public static let powerCPU: Double = 0.75
    public static let powerGPU: Double = 0.70
    public static let powerANE: Double = 0.80
    public static let powerDRAM: Double = 0.55
    /// GPU frequency overlay: `gpuAlt` 1.25 pt @ 0.7, dash [3, 3].
    public static let gpuFrequency: Double = 0.7
    public static let gpuFrequencyDash: [CGFloat] = [3, 3]
}

/// Raw hex values for contrast math and AppKit drawing.
public enum TTHex {
    public static let bgWindow: UInt32 = 0x1B1B1D
    public static let bgHeader: UInt32 = 0x202023
    public static let bgCard: UInt32 = 0x232326
    public static let bgSidebar: UInt32 = 0x242427
    public static let bgPopover: UInt32 = 0x28282C
    public static let bgElevated: UInt32 = 0x2C2C30
    public static let textPrimary: UInt32 = 0xF2F2F4
    public static let textSecondary: UInt32 = 0xA8A8B0
    public static let textTertiary: UInt32 = 0x9A9AA2
    public static let statusElevated: UInt32 = 0xFFB340
    public static let statusCritical: UInt32 = 0xFF453A

    /// WCAG 2.x relative luminance.
    public static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF) + 0.7152 * channel((hex >> 8) & 0xFF) + 0.0722 * channel(hex & 0xFF)
    }

    /// WCAG contrast ratio (≥ 1).
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
