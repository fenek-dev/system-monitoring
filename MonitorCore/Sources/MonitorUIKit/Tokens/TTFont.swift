import SwiftUI

/// DESIGN §1.2. SF Pro (system) everywhere; tabular digits on every style (§0 "Numerals").
public enum TTFont {
    private static func sf(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    public static let display = sf(26, .semibold)
    public static let displayUnit = sf(15)
    public static let title1 = sf(24, .semibold)
    public static let title1Unit = sf(14)
    public static let title2 = sf(22, .semibold)
    public static let title2Unit = sf(13)
    public static let stat = sf(20, .semibold)
    public static let statMedium = sf(18, .semibold)
    public static let pageTitle = sf(15, .semibold)
    public static let dialogTitle = sf(14, .semibold)
    public static let sectionTitle = sf(13, .semibold)
    public static let body13 = sf(13)
    public static let body13Value = sf(13, .semibold)
    public static let button13 = sf(13, .medium)
    public static let body12 = sf(12)
    public static let body12Strong = sf(12, .semibold)
    public static let button12 = sf(12, .medium)
    /// Use with `.lineSpacing(TTFont.body12ParaSpacing)`.
    public static let body12Para = sf(12)
    public static let body12ParaSpacing: CGFloat = 4
    /// Use with `.lineSpacing(TTFont.bannerTextSpacing)`.
    public static let bannerText = sf(12)
    public static let bannerTextSpacing: CGFloat = 3
    public static let caption = sf(11)
    public static let captionMedium = sf(11, .medium)
    public static let captionStrong = sf(11, .semibold)
    public static let mono11 = Font.system(size: 11, design: .monospaced)
    public static let micro = sf(10)
    public static let tileLetter16 = sf(9, .bold)
    public static let tileLetter20 = sf(10, .bold)
    public static let tileLetter26 = sf(13, .bold)
    public static let tileLetter44 = sf(20, .bold)

    /// W0b placeholder name kept for source compatibility (= `title2`).
    public static let largeValue = title2
}
