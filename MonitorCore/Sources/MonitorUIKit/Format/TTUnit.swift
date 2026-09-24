/// Unit spacing (DESIGN §5.1): "%" and "°…" attach directly; other units follow a space.
public enum TTUnit {
    public static func spaced(_ unit: String) -> String {
        if unit.isEmpty || unit.hasPrefix(" ") || unit.hasPrefix("%") || unit.hasPrefix("°") { return unit }
        return " " + unit
    }

    /// "15.2" + "GB" → "15.2 GB"; nil/"—" value → nil (units are dropped when unavailable).
    public static func join(_ value: String?, _ unit: String?) -> String? {
        guard let value, value != TTFormat.unavailable else { return nil }
        guard let unit else { return value }
        return value + spaced(unit)
    }
}
