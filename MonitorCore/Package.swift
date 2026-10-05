// swift-tools-version:6.0
import PackageDescription

// Private libraries are weak-linked: a missing/renamed library on a future macOS makes one sensor
// unavailable instead of failing app launch (ARCHITECTURE §1). ld applies -syslibroot to absolute -F
// paths, so the private framework resolves inside the SDK. swiftc (the link driver) rejects the
// ld-only `-weak-l`/`-weak_framework` options, so they are forwarded with -Xlinker.
let privateLinks: [LinkerSetting] = [
    .unsafeFlags([
        "-F/System/Library/PrivateFrameworks",
        "-Xlinker", "-weak-lIOReport",
        "-Xlinker", "-weak_framework", "-Xlinker", "NetworkStatistics",
        "-Xlinker", "-weak_framework", "-Xlinker", "DisplayServices",
    ]),
]

let package = Package(
    name: "MonitorCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MonitorModel", targets: ["MonitorModel"]),
        .library(name: "MonitorLive", targets: ["MonitorLive"]),
        .library(name: "MonitorRuntime", targets: ["MonitorRuntime"]),
        .library(name: "MonitorScreens", targets: ["MonitorScreens"]),
        .library(name: "MonitorUIKit", targets: ["MonitorUIKit"]),
        .library(name: "MonitorExtraDim", targets: ["MonitorExtraDim"]),
        // The app's Extra Dim adapters read the backlight through DisplayServices.h (weak, tt_*_available()).
        .library(name: "CPrivate", targets: ["CPrivate"]),
        .library(name: "MixerCore", targets: ["MixerCore"]),
        .library(name: "ClipboardCore", targets: ["ClipboardCore"]),
        .library(name: "ClipboardStore", targets: ["ClipboardStore"]),
        .executable(name: "telltale-render", targets: ["telltale-render"]),
        .executable(name: "telltale-probe", targets: ["telltale-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // C: private declarations (weak) + SMC shim.
        .target(name: "CPrivate", linkerSettings: privateLinks),

        // Pure Foundation: all shared value types + protocols (locked, ARCHITECTURE §5).
        .target(name: "MonitorModel"),

        .target(name: "MonitorLive", dependencies: ["MonitorModel"]),
        // Pure Extra Dim logic (state machine, effect runner, dim curve, gamma table/session policy behind
        // protocols); no AppKit/CoreGraphics/time.
        .target(name: "MonitorExtraDim"),
        .target(name: "MonitorEngine", dependencies: ["MonitorModel"]),
        .target(
            name: "MonitorSensors",
            dependencies: ["MonitorModel", "CPrivate"],
            resources: [.process("SoC/Resources"), .process("Thermal/Resources")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .target(
            name: "MonitorStore",
            dependencies: ["MonitorModel", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "MonitorUIKit", dependencies: ["MonitorModel"]),
        // Per-app volume (Core Audio process taps), from the standalone Volume Mixer; Swift 5 mode as written there.
        .target(name: "MixerCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Clipboard history: pure model, pasteboard classifier and fuzzy matcher; the store keeps SQLite + image files.
        .target(name: "ClipboardCore"),
        .target(
            name: "ClipboardStore",
            dependencies: ["ClipboardCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Test-support library (imports Testing): assertSnapshot. Never linked by the app.
        .target(name: "MonitorSnapshotTesting", dependencies: ["MonitorUIKit", "SnapshotProcessSetup"]),
        // ObjC, test-only: image constructor sets AppleFontSmoothing = 0 before any test lays out text.
        .target(name: "SnapshotProcessSetup", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "MonitorMocks", dependencies: ["MonitorModel"]),
        // Storage scanner, classifier, cleaner, scan cache (ICR 018). No AppKit; UI targets never import it.
        .target(name: "MonitorDiskTools", dependencies: ["MonitorModel", "CPrivate"]),
        .target(
            name: "MonitorScreens",
            dependencies: ["MonitorModel", "MonitorLive", "MonitorUIKit", "MonitorMocks", "ClipboardCore"]
        ),
        .target(
            name: "MonitorRuntime",
            dependencies: [
                "MonitorModel", "MonitorLive", "MonitorEngine", "MonitorSensors", "MonitorStore", "MonitorMocks",
                "MonitorDiskTools",
            ]
        ),
        .executableTarget(
            name: "telltale-render",
            dependencies: ["MonitorScreens", "MonitorUIKit", "MonitorMocks", "MonitorLive"]
        ),
        .executableTarget(
            name: "telltale-probe",
            dependencies: ["MonitorModel", "MonitorEngine", "MonitorSensors", "MonitorStore", "MonitorDiskTools", "CPrivate"]
        ),

        // Tests
        .testTarget(name: "MonitorModelTests", dependencies: ["MonitorModel"]),
        .testTarget(name: "MonitorLiveTests", dependencies: ["MonitorLive", "MonitorModel"]),
        .testTarget(name: "MonitorExtraDimTests", dependencies: ["MonitorExtraDim"]),
        .testTarget(
            name: "MonitorEngineTests",
            dependencies: ["MonitorEngine", "MonitorModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MonitorStoreTests", dependencies: ["MonitorStore", "MonitorModel"], exclude: ["Golden"]),
        .testTarget(
            name: "MonitorUIKitTests",
            dependencies: ["MonitorUIKit", "MonitorModel", "MonitorSnapshotTesting"],
            exclude: ["__Snapshots__"]
        ),
        .testTarget(
            name: "MonitorScreensTests",
            dependencies: [
                "MonitorScreens", "MonitorUIKit", "MonitorLive", "MonitorMocks", "MonitorModel", "MonitorSnapshotTesting",
                "ClipboardCore",
            ],
            exclude: ["__Snapshots__"]
        ),
        .testTarget(
            name: "MonitorSensorsTests",
            dependencies: ["MonitorSensors", "MonitorModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MonitorMocksTests", dependencies: ["MonitorMocks", "MonitorModel"]),
        .testTarget(
            name: "MonitorDiskToolsTests",
            dependencies: ["MonitorDiskTools", "MonitorModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore"]),
        .testTarget(name: "ClipboardStoreTests", dependencies: ["ClipboardStore", "ClipboardCore"]),
        .testTarget(
            name: "MonitorRuntimeTests",
            dependencies: [
                "MonitorRuntime", "MonitorModel", "MonitorMocks", "MonitorStore", "MonitorEngine", "MonitorDiskTools",
                "MonitorLive",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
