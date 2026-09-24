// ARCHITECTURE §5.11. Drives MockDataProvider (`.calm` reproduces the design artboards' numbers).

public enum MockScenario: String, CaseIterable, Sendable, Codable {
    case calm, thermalFair, thermalCritical, memoryWarning, memoryCritical, runaway
    case collecting, sensorsUnavailable, paused
    /// Many .restricted/.coalition rows, rss memory, synthetic coalition rows.
    case restricted
}
