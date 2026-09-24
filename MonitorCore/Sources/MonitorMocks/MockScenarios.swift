// ARCHITECTURE §5.11. Drives MockDataProvider (`.calm` reproduces the design artboards' numbers).

public enum MockScenario: String, CaseIterable, Sendable, Codable {
    case calm, thermalFair, thermalCritical, memoryWarning, memoryCritical, runaway
    case collecting, sensorsUnavailable, paused
    /// Many .restricted/.coalition rows, rss memory, synthetic coalition rows.
    case restricted
    /// U-I2: the device facts are not known — SMC unreachable (fan count nil, no fans/SMC temps) and battery
    /// presence unknown with no battery reading. The UI must show "—"/"Collecting…", never "no fans" or "AC power".
    case deviceUnknown
}
