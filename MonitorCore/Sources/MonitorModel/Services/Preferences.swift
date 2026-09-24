import Foundation

public struct UnitPreferences: Sendable, Codable, Equatable {
    public enum Temperature: String, Sendable, Codable, CaseIterable { case celsius, fahrenheit }
    public enum NetworkRate: String, Sendable, Codable, CaseIterable { case bytes, bits }

    public var temperature: Temperature = .celsius, networkRate: NetworkRate = .bytes

    public init(temperature: Temperature = .celsius, networkRate: NetworkRate = .bytes) {
        self.temperature = temperature
        self.networkRate = networkRate
    }
}

/// Popover row order/visibility, edited in Settings (ruling).
public struct PopoverLayout: Sendable, Codable, Equatable {
    public var order: [Category] = Category.allCases, hidden: Set<Category> = []

    public init(order: [Category] = Category.allCases, hidden: Set<Category> = []) {
        self.order = order
        self.hidden = hidden
    }
}
