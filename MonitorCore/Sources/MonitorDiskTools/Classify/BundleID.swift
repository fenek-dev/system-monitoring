import Foundation

/// Bundle-ID normalization for `~/Library` names (spec §6.1).
public enum BundleID {
    private static let strippedSuffixes = [".plist", ".savedstate", ".binarycookies"]

    /// Lowercased ID with team-ID prefix, `group.`/`groups.` prefix and file suffix removed; nil when nothing
    /// bundle-ID-shaped is left (a bare word, e.g. `UBF8T346G9.Office` → `office`), so such names are never flagged.
    public static func normalize(_ name: String) -> String? {
        // The team-ID pattern is uppercase: it must be stripped before lowercasing.
        var s = stripTeamID(name).lowercased()
        for prefix in ["groups.", "group."] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        for suffix in strippedSuffixes where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
            break
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        return s
    }

    public static func isAppleOwned(_ normalized: String) -> Bool {
        normalized.contains("com.apple.")
    }

    /// `^[A-Z0-9]{10}\.`
    private static func stripTeamID(_ name: String) -> String {
        let bytes = Array(name.utf8)
        guard bytes.count > 11, bytes[10] == UInt8(ascii: ".") else { return name }
        let isTeamID = bytes[0 ..< 10].allSatisfy {
            ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
        }
        return isTeamID ? String(decoding: bytes[11...], as: UTF8.self) : name
    }
}
