import Foundation

/// DESIGN §0 "Text rendering: antialiased and not bold-adjusted" — the artboards' `-webkit-font-smoothing:
/// antialiased`. CoreText's font smoothing (stem darkening, on by default) renders every weight about one step heavier
/// than the reference. `configure()` turns it off for this process only (argument-domain default
/// `AppleFontSmoothing = 0`; nothing is persisted, no system setting changes).
///
/// Call it first thing in `main` (before `NSApplication.shared` / any text drawing). `SnapshotRenderer` calls it
/// before every render, so goldens and telltale-render match the reference.
/// Measured ink on "Open Dashboard" 13/medium: 0.4780 with smoothing, 0.4715 without, 0.4721 Chrome reference.
public enum TTTextRendering {
    public static func configure() {
        let defaults = UserDefaults.standard
        var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard domain["AppleFontSmoothing"] as? Int != 0 else { return }
        domain["AppleFontSmoothing"] = 0
        defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }
}
