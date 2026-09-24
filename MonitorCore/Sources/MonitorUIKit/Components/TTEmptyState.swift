import SwiftUI

/// DESIGN §3.15 global states, centered in the frame it is given:
/// - `collecting`: "Collecting…" `caption` `textTertiary` (charts with < 2 samples);
/// - `unavailable(msg)` / `empty(msg)`: `body12` `textSecondary` ("This Mac has no fans", "No GPU clients");
/// - `paused`: "Sampling paused" `caption` `textTertiary`.
public struct TTEmptyState: View {
    public enum Kind: Equatable, Sendable { case collecting(since: Date?), unavailable(String), empty(String), paused }

    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public var body: some View {
        Group {
            switch kind {
            case .collecting:
                Text("Collecting…").font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
            case .paused:
                Text("Sampling paused").font(TTFont.caption).foregroundStyle(TTColor.textTertiary)
            case .unavailable(let message), .empty(let message):
                Text(message).font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// DESIGN §3.15 "Store error": centered `body12` message plus a `caption` `textTertiary` detail.
public struct TTErrorState: View {
    let title: String
    let detail: String?
    public init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
    public var body: some View {
        VStack(spacing: TTSpace.x4) {
            Text(title).font(TTFont.body12).foregroundStyle(TTColor.textSecondary)
            if let detail { Text(detail).font(TTFont.caption).foregroundStyle(TTColor.textTertiary) }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
