import AppKit
import MonitorModel
import SwiftUI

/// DESIGN §2.19 app tile. Sizes 16 (child rows, radius 4), 20 (tables, radius 5), 26 (popover, radius 7),
/// 44 (inspector, radius 10). Bundle icon when available (cached, `NSWorkspace.icon(forFile:)`), else a letter
/// tile: palette color by FNV-1a of the bundle id / executable name, uppercase first alphanumeric in white.
/// Snapshots always use the letter tile (icons differ per machine).
public struct TTAppTile: View, Equatable {
    let identity: AppIdentity?
    let name: String
    let size: CGFloat
    @Environment(\.isSnapshot) private var isSnapshot

    public init(identity: AppIdentity?, name: String, size: CGFloat = 20) {
        self.identity = identity
        self.name = name
        self.size = size
    }

    public nonisolated static func == (a: Self, b: Self) -> Bool {
        a.identity == b.identity && a.name == b.name && a.size == b.size
    }

    /// Hash key: bundle id for apps, executable name for processes, else the display name.
    var tileKey: String {
        guard let identity else { return name }
        switch identity.key.kind {
        case .app: return identity.key.id
        case .process: return (identity.key.id as NSString).lastPathComponent
        case .system, .other: return identity.key.id
        }
    }

    var letter: String { Self.letter(name.isEmpty ? (identity?.displayName ?? "") : name) }

    var radius: CGFloat { Self.radius(size) }

    /// Uppercase first alphanumeric character ("?" when none): "com.docker.backend" → "C".
    nonisolated static func letter(_ name: String) -> String {
        guard let c = name.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(c).uppercased()
    }

    /// 16 → 4, 20 → 5, 26 → 7, 44 → 10.
    nonisolated static func radius(_ size: CGFloat) -> CGFloat {
        switch size {
        case ..<18: TTRadius.r4
        case ..<24: TTRadius.r5
        case ..<35: TTRadius.r7
        default: TTRadius.card
        }
    }

    var letterFont: Font {
        switch size {
        case ..<18: TTFont.tileLetter16
        case ..<24: TTFont.tileLetter20
        case ..<35: TTFont.tileLetter26
        default: TTFont.tileLetter44
        }
    }

    public var body: some View {
        Group {
            if !isSnapshot, let path = identity?.bundlePath, let icon = AppIconCache.icon(forPath: path) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(TTColor.tile(for: tileKey))
                    .overlay(
                        Text(letter).font(letterFont).foregroundStyle(TTColor.textOnAccent)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// App icons cached per bundle path (ARCHITECTURE §7: `NSCache`).
@MainActor enum AppIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 256
        return c
    }()

    static func icon(forPath path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}
