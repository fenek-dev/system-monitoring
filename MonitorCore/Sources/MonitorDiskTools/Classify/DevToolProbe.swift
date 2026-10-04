import Foundation

/// Facts about the developer toolchain. Probing is lazy and never touches bare `xcrun` / `git` stubs, which pop the
/// Command Line Tools install dialog when no toolchain is selected.
public protocol DevToolProbe: Sendable {
    /// `xcode-select -p` exits 0.
    var xcodeSelectOK: Bool { get }
    /// UDIDs `xcrun simctl delete unavailable` would remove. Only called when `xcodeSelectOK`.
    func unavailableSimulatorUDIDs() -> [String]
}

public struct LiveDevToolProbe: DevToolProbe {
    public init() {}

    public var xcodeSelectOK: Bool {
        do {
            return try ProcessRun.run("/usr/bin/xcode-select", ["-p"], timeout: 5).status == 0
        } catch {
            DiskTools.log.error("xcode-select -p failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func unavailableSimulatorUDIDs() -> [String] {
        do {
            let out = try ProcessRun.run(
                "/usr/bin/xcrun", ["simctl", "list", "-j", "devices", "unavailable"], timeout: 20)
            guard out.status == 0 else {
                DiskTools.log.error("simctl list exited \(out.status)")
                return []
            }
            return Self.parseUnavailable(out.stdout)
        } catch {
            DiskTools.log.error("simctl list failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// `{"devices": {"<runtime>": [{"udid": …, "isAvailable": false}, …]}}`
    static func parseUnavailable(_ json: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]]
        else {
            DiskTools.log.error("simctl list: unexpected JSON")
            return []
        }
        return runtimes.values.flatMap { $0 }
            .filter { ($0["isAvailable"] as? Bool) == false }
            .compactMap { $0["udid"] as? String }
            .sorted()
    }
}
