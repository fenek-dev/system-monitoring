import AppKit
import MonitorModel
import SwiftUI
import UniformTypeIdentifiers

/// DESIGN §2.19 app tile. Sizes 16 (child rows, radius 4), 20 (tables, radius 5), 26 (popover, radius 7),
/// 44 (inspector, radius 10). Bundle icon when available (cached, `NSWorkspace.icon(forFile:)`), else a letter
/// tile: palette color by FNV-1a of the bundle id / executable name, uppercase first alphanumeric in white.
/// Real icons only for proper app bundles with a non-generic icon (see `AppIconCache`). Snapshots use the letter tile
/// (icons differ per machine) unless `\.ttAppIconsInSnapshots` is set.
public struct TTAppTile: View, Equatable {
    let identity: AppIdentity?
    let name: String
    let size: CGFloat
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.ttAppIconsInSnapshots) private var iconsInSnapshots

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
            if !isSnapshot || iconsInSnapshots, let path = identity?.bundlePath, let icon = AppIconCache.icon(forPath: path) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(TTColor.tiles[TTColor.tileIndex(key: tileKey, name: name.isEmpty ? identity?.displayName : name)])
                    .overlay(
                        Text(letter).font(letterFont).foregroundStyle(TTColor.textOnAccent)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// App icons cached per bundle path (ARCHITECTURE §7). Ruling (CP2): the real icon is used only for a proper `.app`
/// bundle that declares its own icon (CFBundleIconFile / CFBundleIconName / CFBundleIcons) and whose icon is not
/// the generic application/executable/document icon; otherwise nil → letter tile. Negative results are cached too.
@MainActor enum AppIconCache {
    private final class Entry {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    private static let cache: NSCache<NSString, Entry> = {
        let c = NSCache<NSString, Entry>()
        c.countLimit = 256
        return c
    }()

    static func icon(forPath path: String) -> NSImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit.image }
        let icon = hasCustomIcon(bundlePath: path) ? NSWorkspace.shared.icon(forFile: path) : nil
        let usable = icon.flatMap { isGeneric($0) ? nil : $0 }
        cache.setObject(Entry(usable), forKey: path as NSString)
        return usable
    }

    /// A `.app` bundle whose Info.plist names an icon.
    nonisolated static func hasCustomIcon(bundlePath path: String) -> Bool {
        guard path.hasSuffix(".app"), let bundle = Bundle(path: path), let info = bundle.infoDictionary else { return false }
        return info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil || info["CFBundleIcons"] != nil
    }

    private static let genericIcons: [Data] = [UTType.application, .unixExecutable, .data, .applicationBundle]
        .compactMap { thumbnail(NSWorkspace.shared.icon(for: $0)) }

    /// 16×16 rasterization used to compare against the generic system icons.
    private static func thumbnail(_ image: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 64, bitsPerPixel: 32) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        return Data(bytes: data, count: 16 * 64)
    }

    /// Generic system icon, or blank (all pixels near-white or transparent).
    static func isGeneric(_ image: NSImage) -> Bool {
        guard let t = thumbnail(image) else { return true }
        if genericIcons.contains(t) { return true }
        var opaque = 0, whiteish = 0
        for i in stride(from: 0, to: t.count, by: 4) where t[i + 3] > 32 {
            opaque += 1
            if t[i] > 235 && t[i + 1] > 235 && t[i + 2] > 235 { whiteish += 1 }
        }
        return opaque == 0 || Double(whiteish) / Double(opaque) > 0.9
    }
}
