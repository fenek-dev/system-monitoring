import Foundation

/// Temp directory with fake `.app` bundles (Info.plist + an empty executable) for resolver tests.
final class FakeBundles {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tt-bundles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Creates `<root>/<relative>.app` and returns the executable path inside it.
    @discardableResult
    func app(_ relative: String, bundleID: String?, displayName: String? = nil, name: String? = nil,
             executable: String = "main") throws -> String {
        let bundle = root.appendingPathComponent(relative + ".app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleExecutable": executable, "CFBundlePackageType": "APPL"]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        if let displayName { plist["CFBundleDisplayName"] = displayName }
        if let name { plist["CFBundleName"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let exe = macOS.appendingPathComponent(executable)
        FileManager.default.createFile(atPath: exe.path, contents: Data())
        return exe.path
    }

    func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relative + ".app"))
    }
}
