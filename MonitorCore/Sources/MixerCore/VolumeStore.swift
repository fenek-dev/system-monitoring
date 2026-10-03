import Foundation

public struct AppVolume: Codable, Equatable, Sendable {
    /// Slider position at the top of the boost range.
    public static let maxVolume: Float = 1.5

    /// Slider position, 0...1.5. 1 is the app's own level; above that is boost.
    public var volume: Float
    public var muted: Bool

    public init(volume: Float = 1, muted: Bool = false) {
        self.volume = volume.isNaN ? 1 : min(max(volume, 0), Self.maxVolume)
        self.muted = muted
    }

    public var isDefault: Bool { volume == 1 && !muted }
}

public final class VolumeStore {
    private let defaults: UserDefaults
    private let key: String
    private var cache: [String: AppVolume]
    private var hiddenIDs: Set<String>

    private var hiddenKey: String { key + ".hidden" }

    public init(defaults: UserDefaults = .standard, key: String = "appVolumes") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: AppVolume].self, from: data) {
            // Synthesized decoding skips init, so clamp here.
            cache = decoded.mapValues { AppVolume(volume: $0.volume, muted: $0.muted) }
        } else {
            cache = [:]
        }
        hiddenIDs = Set(defaults.stringArray(forKey: key + ".hidden") ?? [])
    }

    public var all: [String: AppVolume] { cache }

    /// Apps the user removed from the list. Their volumes still apply.
    public var hidden: Set<String> { hiddenIDs }

    public func volume(for bundleID: String) -> AppVolume {
        cache[bundleID] ?? AppVolume()
    }

    public func set(_ volume: AppVolume, for bundleID: String) {
        cache[bundleID] = volume.isDefault ? nil : volume
        defaults.set(try? JSONEncoder().encode(cache), forKey: key)
    }

    public func setHidden(_ hidden: Bool, for bundleID: String) {
        if hidden {
            hiddenIDs.insert(bundleID)
        } else {
            hiddenIDs.remove(bundleID)
        }
        defaults.set(hiddenIDs.sorted(), forKey: hiddenKey)
    }
}
