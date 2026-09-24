// swift-tools-version:6.0
import PackageDescription

// ld applies -syslibroot to absolute -F paths, so this resolves inside the SDK.
let privateLinks: [LinkerSetting] = [
    .linkedFramework("IOKit"),
    .linkedLibrary("IOReport"),
    .linkedLibrary("sysmon"),
    .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "NetworkStatistics"]),
]

let package = Package(
    name: "Spikes",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CPrivate", linkerSettings: privateLinks),
        .executableTarget(name: "spike-procs", dependencies: ["CPrivate"]),
        .executableTarget(name: "spike-sysmon", dependencies: ["CPrivate"]),
        .executableTarget(name: "spike-ioreport", dependencies: ["CPrivate"]),
        .executableTarget(name: "spike-temps", dependencies: ["CPrivate"]),
        .executableTarget(name: "spike-smc", dependencies: ["CPrivate"]),
        .executableTarget(name: "spike-gpu-apps", dependencies: ["CPrivate"]),
        .executableTarget(name: "spike-nstat", dependencies: ["CPrivate"]),
        .executableTarget(name: "spike-extras", dependencies: ["CPrivate"]),
    ],
    swiftLanguageModes: [.v5]
)
