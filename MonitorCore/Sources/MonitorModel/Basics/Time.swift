import Foundation

public enum SamplingMode: String, Sendable, Codable {
    case background, interactive, paused
    /// Only the on-screen overlay is visible: totals every tick, everything else at the background cadence.
    case overlay

    /// 5 s, 1 s, nil (no sampling while paused), 1 s.
    public var interval: Duration? {
        switch self {
        case .background: .seconds(5)
        case .interactive: .seconds(1)
        case .paused: nil
        case .overlay: .seconds(1)
        }
    }
}

/// Chart range: Live / 1H / 24H / 7D / 30D.
public enum HistoryRange: String, CaseIterable, Sendable, Codable {
    case live, hour, day, week, month

    /// Length of the window. Live = the last 60 s of the in-memory ring buffers.
    public var duration: Duration? {
        switch self {
        case .live: .seconds(60)
        case .hour: .seconds(3_600)
        case .day: .seconds(86_400)
        case .week: .seconds(7 * 86_400)
        case .month: .seconds(30 * 86_400)
        }
    }

    public var label: String {
        switch self {
        case .live: "Live"
        case .hour: "1H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        }
    }

    /// DESIGN.md §5.10: Live 1 s, 1H 15 s, 24H 5 min, 7D 30 min, 30D 2 h.
    public var displayBucket: Duration {
        switch self {
        case .live: .seconds(1)
        case .hour: .seconds(15)
        case .day: .seconds(5 * 60)
        case .week: .seconds(30 * 60)
        case .month: .seconds(2 * 3_600)
        }
    }
}
