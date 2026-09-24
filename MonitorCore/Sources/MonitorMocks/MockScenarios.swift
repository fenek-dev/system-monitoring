// W0b stub (ARCHITECTURE §5.11). Wm replaces this file.

public enum MockScenario: String, CaseIterable, Sendable, Codable {
    case calm, thermalFair, thermalCritical, memoryWarning, memoryCritical, runaway
    case collecting, sensorsUnavailable, paused
    /// Many .restricted/.coalition rows, rss memory, synthetic coalition rows.
    case restricted
}
